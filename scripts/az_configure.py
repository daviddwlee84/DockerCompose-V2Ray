#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
Render ansible inventory + per-host vaults from the Azure VMs provisioned by az_up.sh.

Reads:
    .secrets/azure/vms/<rg>.json   one file per VM (primary, supports multi-host)
    .secrets/azure/last-vm.json    legacy single-VM handoff (fallback if vms/ is empty)

Writes:
    ansible/inventory/prod.ini                        one [vpn] line per tracked VM
    ansible/host_vars/<rg>/vault.yml                  per-host, ansible-vault encrypted

Vault password resolution order:
    1. $ANSIBLE_VAULT_PASSWORD_FILE
    2. ~/.vault-pass
    3. .secrets/.vault-pass                (auto-generated if missing)

LE email resolution order:
    1. $LE_EMAIL
    2. `git config user.email` (must be set and look like a real email)

Usage:
    scripts/az_configure.py                # render inventory + vaults for all tracked VMs
    scripts/az_configure.py --force        # regenerate per-host vaults (new UUIDs); wipe stale host_vars/
    scripts/az_configure.py --rg <rg>      # limit to a single RG (leaves other vaults/inventory entries alone)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
VMS_DIR = REPO_ROOT / ".secrets" / "azure" / "vms"
LEGACY_LAST_VM = REPO_ROOT / ".secrets" / "azure" / "last-vm.json"
VAULT_PASS_LOCAL = REPO_ROOT / ".secrets" / ".vault-pass"
INVENTORY = REPO_ROOT / "ansible" / "inventory" / "prod.ini"
HOST_VARS_DIR = REPO_ROOT / "ansible" / "host_vars"
# Legacy single-file vault. We preserve it (if it exists and is encrypted)
# so operators who still use the non-throwaway flow aren't disturbed; we
# just don't write to it any more.
LEGACY_GROUP_VAULT = REPO_ROOT / "ansible" / "group_vars" / "vpn" / "vault.yml"


def die(msg: str) -> None:
    print(f"[az-configure] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg: str) -> None:
    print(f"[az-configure] {msg}", file=sys.stderr)


def resolve_vault_pass_file() -> Path:
    env = os.environ.get("ANSIBLE_VAULT_PASSWORD_FILE")
    if env and Path(env).expanduser().is_file():
        return Path(env).expanduser()

    home_pass = Path.home() / ".vault-pass"
    if home_pass.is_file():
        return home_pass

    if VAULT_PASS_LOCAL.is_file():
        return VAULT_PASS_LOCAL

    VAULT_PASS_LOCAL.parent.mkdir(parents=True, exist_ok=True)
    VAULT_PASS_LOCAL.write_text(secrets.token_hex(32) + "\n")
    VAULT_PASS_LOCAL.chmod(0o600)
    log(f"Generated fresh vault password at {VAULT_PASS_LOCAL} (keep it, or delete to regenerate)")
    return VAULT_PASS_LOCAL


_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def resolve_le_email() -> str:
    env = os.environ.get("LE_EMAIL", "").strip()
    if env:
        if not _EMAIL_RE.match(env):
            die(f"LE_EMAIL={env!r} does not look like an email address")
        return env

    try:
        out = subprocess.run(
            ["git", "config", "--get", "user.email"],
            capture_output=True,
            text=True,
            check=False,
            cwd=REPO_ROOT,
        )
    except FileNotFoundError:
        die("git not on PATH and LE_EMAIL not set — can't determine Let's Encrypt email")

    email = out.stdout.strip()
    if not email or not _EMAIL_RE.match(email) or "example.com" in email:
        die(
            "Could not resolve a real email for Let's Encrypt. "
            "Set LE_EMAIL=you@example.org, or configure git user.email."
        )
    return email


def load_vms(only_rg: str | None = None) -> list[dict]:
    """Return every tracked VM as a list of dicts.

    Prefers vms/<rg>.json; falls back to legacy last-vm.json only when the
    vms/ dir is empty (so callers don't see duplicated entries during the
    transitional period where az_up.sh writes both).
    """
    vms: list[dict] = []
    seen: set[str] = set()

    if VMS_DIR.is_dir():
        for path in sorted(VMS_DIR.glob("*.json")):
            # 'current' is a symlink to one of the *.json files; reading it
            # directly would dup whatever it points at. Skip.
            if path.name == "current":
                continue
            try:
                data = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                log(f"WARN: failed to read {path.relative_to(REPO_ROOT)}: {exc}")
                continue
            rg = data.get("rg")
            if not rg:
                log(f"WARN: {path.relative_to(REPO_ROOT)} has no .rg, skipping")
                continue
            for key in ("fqdn", "admin_user"):
                if not data.get(key):
                    die(f"{path.relative_to(REPO_ROOT)} missing required field: {key}")
            if rg in seen:
                continue
            seen.add(rg)
            vms.append(data)

    if not vms and LEGACY_LAST_VM.is_file():
        data = json.loads(LEGACY_LAST_VM.read_text())
        for key in ("rg", "fqdn", "admin_user"):
            if not data.get(key):
                die(f"{LEGACY_LAST_VM} missing required field: {key}")
        vms.append(data)
        log(f"(no vms/*.json found; using legacy {LEGACY_LAST_VM.relative_to(REPO_ROOT)})")

    if only_rg is not None:
        vms = [v for v in vms if v.get("rg") == only_rg]
        if not vms:
            die(f"--rg {only_rg!r} not found in {VMS_DIR.relative_to(REPO_ROOT)}/ or {LEGACY_LAST_VM.relative_to(REPO_ROOT)}")

    if not vms:
        die(
            f"no VMs tracked — run `just az-up` first "
            f"(looked in {VMS_DIR.relative_to(REPO_ROOT)}/ and {LEGACY_LAST_VM.relative_to(REPO_ROOT)})"
        )

    return vms


def write_inventory(vms: list[dict]) -> None:
    """Render one [vpn] line per VM. Host name = RG (unique per VM cycle)."""
    INVENTORY.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = [
        "; Auto-generated by scripts/az_configure.py — safe to re-run.",
        "; prod.ini is gitignored (see .gitignore).",
        "",
        "[vpn]",
    ]
    # Per-host SSH key paths go on the host line itself; any vars shared by
    # every Azure VM can live in [vpn:vars] below.
    for vm in vms:
        parts = [
            vm["rg"],
            f"ansible_host={vm['fqdn']}",
            f"ansible_user={vm['admin_user']}",
        ]
        if vm.get("ssh_key"):
            parts.append(f"ansible_ssh_private_key_file={vm['ssh_key']}")
            parts.append(f"ansible_private_key_file={vm['ssh_key']}")
        lines.append(" ".join(parts))

    lines += [
        "",
        "[vpn:vars]",
        "; Per-host overrides live in ansible/host_vars/<rg>/vault.yml.",
        "",
    ]
    INVENTORY.write_text("\n".join(lines))
    log(f"Wrote {INVENTORY.relative_to(REPO_ROOT)} ({len(vms)} host{'s' if len(vms) != 1 else ''})")


def vault_is_encrypted(path: Path) -> bool:
    if not path.is_file():
        return False
    with path.open("rb") as fh:
        head = fh.read(64)
    return head.startswith(b"$ANSIBLE_VAULT;")


def write_host_vault(vm: dict, email: str, vault_pass_file: Path, force: bool) -> bool:
    """Write + encrypt ansible/host_vars/<rg>/vault.yml. Returns True if (re)written."""
    host_dir = HOST_VARS_DIR / vm["rg"]
    vault_file = host_dir / "vault.yml"

    if vault_is_encrypted(vault_file) and not force:
        log(f"  [{vm['rg']}] vault.yml already encrypted — keeping existing UUID (use --force to rotate)")
        return False

    if not shutil.which("ansible-vault"):
        die("ansible-vault not on PATH — install ansible-core")

    v2ray_uuid = str(uuid.uuid4())
    host_dir.mkdir(parents=True, exist_ok=True)
    plaintext = (
        "---\n"
        "# Auto-generated by scripts/az_configure.py. Re-run with --force to rotate.\n"
        f"vault_domain: {vm['fqdn']}\n"
        f"vault_letsencrypt_email: {email}\n"
        f'vault_v2ray_uuid: "{v2ray_uuid}"\n'
    )
    vault_file.write_text(plaintext)
    vault_file.chmod(0o600)

    # Scrub ANSIBLE_VAULT_PASSWORD_FILE from the subprocess env so ansible-vault
    # doesn't see two "default" vault IDs (env + --vault-password-file) and bail
    # with "Specify the vault-id to encrypt with --encrypt-vault-id".
    env = {k: v for k, v in os.environ.items() if k != "ANSIBLE_VAULT_PASSWORD_FILE"}
    subprocess.run(
        ["ansible-vault", "encrypt", "--vault-password-file", str(vault_pass_file), str(vault_file)],
        check=True,
        env=env,
    )
    log(f"  [{vm['rg']}] wrote + encrypted {vault_file.relative_to(REPO_ROOT)}")
    log(f"    vault_domain            = {vm['fqdn']}")
    log(f"    vault_v2ray_uuid        = {v2ray_uuid}")
    return True


def ensure_vpn_vars_aliases() -> None:
    """Sanity-check that group_vars/vpn/vars.yml is still the plain-name alias
    layer. We don't touch it, but we warn if it's missing so the user doesn't
    hit a confusing undefined-variable error at deploy time."""
    vars_file = REPO_ROOT / "ansible" / "group_vars" / "vpn" / "vars.yml"
    if not vars_file.is_file():
        log(f"WARN: {vars_file.relative_to(REPO_ROOT)} is missing — templates rely on it for plain-name aliases (domain / v2ray_uuid).")


def prune_stale_host_vars(keep_rgs: set[str], dry_run: bool) -> None:
    """Remove ansible/host_vars/<rg>/ directories that aren't in keep_rgs.

    Only called with --force; otherwise operators' hand-edited host_vars
    for non-throwaway VMs would be clobbered.
    """
    if not HOST_VARS_DIR.is_dir():
        return
    for child in HOST_VARS_DIR.iterdir():
        if not child.is_dir():
            continue
        if child.name in keep_rgs:
            continue
        if dry_run:
            log(f"  would remove stale {child.relative_to(REPO_ROOT)}/")
            continue
        shutil.rmtree(child)
        log(f"  removed stale {child.relative_to(REPO_ROOT)}/")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0] if __doc__ else "")
    p.add_argument("--force", action="store_true",
                   help="Regenerate per-host vaults (new UUIDs) AND prune host_vars/ entries for VMs no longer tracked.")
    p.add_argument("--rg", default=None,
                   help="Limit to a single RG (inventory gets only this host; other host_vars/ untouched).")
    args = p.parse_args()

    vms = load_vms(only_rg=args.rg)
    email = resolve_le_email()
    vault_pass_file = resolve_vault_pass_file()

    ensure_vpn_vars_aliases()

    # Inventory is always rewritten from the current set of tracked VMs, unless
    # the user asked to limit to one RG (in which case we don't clobber other
    # hosts they might have in prod.ini).
    if args.rg is None:
        write_inventory(vms)
    else:
        log(f"(--rg {args.rg} passed; inventory not rewritten. Add the host manually if needed.)")

    log(f"Writing host vaults for {len(vms)} VM{'s' if len(vms) != 1 else ''}:")
    for vm in vms:
        write_host_vault(vm, email, vault_pass_file, force=args.force)

    if args.force and args.rg is None:
        log("Pruning stale host_vars/ (entries for untracked VMs):")
        prune_stale_host_vars({vm["rg"] for vm in vms}, dry_run=False)

    log("")
    log("Vault password file (export for ansible):")
    log(f"  export ANSIBLE_VAULT_PASSWORD_FILE={vault_pass_file}")
    log("")
    if len(vms) == 1:
        log(f"Next: just deploy && DOMAIN={vms[0]['fqdn']} just verify")
    else:
        log("Next: just deploy   # deploys to all tracked VMs")
        for vm in vms:
            log(f"      DOMAIN={vm['fqdn']} just verify   # per-host smoke test")
    return 0


if __name__ == "__main__":
    sys.exit(main())
