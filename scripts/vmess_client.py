#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML>=6", "qrcode[pil]>=7.4"]
# ///
"""
Emit V2Ray / VMess client configs in every common format.

Reads domain + UUID from the per-host ansible-vault–encrypted vault
(`ansible/host_vars/<rg>/vault.yml`), plus the non-secret defaults
(WebSocket path, alterId) from ansible/group_vars/all.yml and the vpn role
defaults. Falls back to the legacy single-host vault at
`ansible/group_vars/vpn/vault.yml` when no per-host layout is present.

With multiple tracked VMs, you must pass `--rg <resource-group>` (or set
`RG=<rg>`). With exactly one tracked VM, defaults to that one.

Writes to out/client/ (or out/client/<rg>/ when --rg is passed):
    vmess.txt      single-line vmess://<base64(json)> URL (v2rayN / Shadowrocket)
    config.json    pretty inner JSON (v2rayN import-from-clipboard fallback)
    clash.yaml     single Clash VMess proxy entry
    human.md       human-readable field table
    qr.png         PNG QR of the vmess:// link (Shadowrocket "scan from album")

Also prints:
    - the human-readable block
    - an ASCII QR in the terminal

Usage:
    scripts/vmess_client.py
    scripts/vmess_client.py --rg vpn-test-you-1234
    scripts/vmess_client.py --remark 'my-tokyo-node'
    scripts/vmess_client.py --out custom/dir
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import qrcode
import qrcode.image.pil
import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent
LEGACY_GROUP_VAULT = REPO_ROOT / "ansible" / "group_vars" / "vpn" / "vault.yml"
HOST_VARS_DIR = REPO_ROOT / "ansible" / "host_vars"
ALL_VARS = REPO_ROOT / "ansible" / "group_vars" / "all.yml"
VPN_DEFAULTS = REPO_ROOT / "ansible" / "roles" / "vpn" / "defaults" / "main.yml"
VMS_DIR = REPO_ROOT / ".secrets" / "azure" / "vms"
VMS_CURRENT = VMS_DIR / "current"
LEGACY_LAST_VM = REPO_ROOT / ".secrets" / "azure" / "last-vm.json"
VAULT_PASS_LOCAL = REPO_ROOT / ".secrets" / ".vault-pass"
OUT_DEFAULT = REPO_ROOT / "out" / "client"


def die(msg: str) -> None:
    print(f"[vmess-client] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg: str) -> None:
    print(f"[vmess-client] {msg}", file=sys.stderr)


def resolve_vault_pass_file() -> Path | None:
    env = os.environ.get("ANSIBLE_VAULT_PASSWORD_FILE")
    if env and Path(env).expanduser().is_file():
        return Path(env).expanduser()

    home_pass = Path.home() / ".vault-pass"
    if home_pass.is_file():
        return home_pass

    if VAULT_PASS_LOCAL.is_file():
        return VAULT_PASS_LOCAL

    return None


def _list_tracked_rgs() -> list[str]:
    """Return RG names that have a vms/<rg>.json state file on disk."""
    if not VMS_DIR.is_dir():
        return []
    names = []
    for p in sorted(VMS_DIR.glob("*.json")):
        if p.name == "current":
            continue
        names.append(p.stem)
    return names


def resolve_target_rg(explicit: str | None) -> str | None:
    """Pick the RG whose vault we should read.

    Rules (matches just az-client / just verify / just az-down):
      - --rg <name>          → use it (error if not tracked)
      - RG env var           → treated like --rg
      - exactly one tracked  → default to it
      - multiple tracked     → list + error (require explicit)
      - zero tracked, legacy last-vm.json present → use its .rg
      - nothing tracked, no legacy → None (fall back to group vault below)
    """
    choice = explicit or os.environ.get("RG", "").strip() or None
    rgs = _list_tracked_rgs()

    if choice:
        if rgs and choice not in rgs:
            die(
                f"--rg {choice!r} is not in .secrets/azure/vms/ "
                f"(tracked: {', '.join(rgs) or '(none)'})"
            )
        return choice

    if len(rgs) == 1:
        return rgs[0]

    if len(rgs) > 1:
        log("Multiple VMs tracked — pass --rg <resource-group> (or RG=<rg>):")
        for name in rgs:
            try:
                data = json.loads((VMS_DIR / f"{name}.json").read_text())
                log(f"  {name}  ({data.get('fqdn', '')})")
            except (OSError, json.JSONDecodeError):
                log(f"  {name}")
        die("no RG selected")

    # Zero tracked VMs in vms/. Try the legacy handoff so older flows still work.
    if LEGACY_LAST_VM.is_file():
        try:
            data = json.loads(LEGACY_LAST_VM.read_text())
            rg = data.get("rg")
            if rg:
                return rg
        except json.JSONDecodeError:
            pass

    return None


def _vault_view(vault_file: Path, vault_pass: Path | None) -> dict:
    cmd = ["ansible-vault", "view"]
    if vault_pass:
        cmd += ["--vault-password-file", str(vault_pass)]
    cmd.append(str(vault_file))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        die(f"ansible-vault view {vault_file} failed — ensure vault password is accessible")
    return yaml.safe_load(result.stdout) or {}


def read_vault(rg: str | None) -> dict:
    """Prefer per-host vault under host_vars/<rg>/vault.yml; fall back to the
    legacy single-host group vault so older setups still work."""
    if not shutil.which("ansible-vault"):
        die("ansible-vault not on PATH — install ansible-core")

    vault_pass = resolve_vault_pass_file()
    candidates: list[Path] = []
    if rg:
        candidates.append(HOST_VARS_DIR / rg / "vault.yml")
    candidates.append(LEGACY_GROUP_VAULT)

    for vault_file in candidates:
        if vault_file.is_file():
            data = _vault_view(vault_file, vault_pass)
            missing = [k for k in ("vault_domain", "vault_v2ray_uuid") if not data.get(k)]
            if missing:
                die(f"{vault_file} is missing: {', '.join(missing)}")
            log(f"Using vault: {vault_file.relative_to(REPO_ROOT)}")
            return data

    searched = ", ".join(str(c.relative_to(REPO_ROOT)) for c in candidates)
    die(f"no vault found (looked at: {searched}) — run `just az-configure` first")


def _parse_yaml_simple(path: Path) -> dict:
    """Jinja-tolerant YAML parse: ansible group_vars may contain {{ ... }} which
    PyYAML handles fine as long as values are quoted or scalars. Templates are
    returned as-is strings; we only care about scalar defaults here."""
    return yaml.safe_load(path.read_text()) or {}


def read_non_secret_defaults() -> dict:
    """Pull v2ray_ws_path + alterId (and any other client-visible knobs) from
    the ansible defaults so client config stays in lockstep with server config."""
    defaults = {}
    for f in (ALL_VARS, VPN_DEFAULTS):
        if f.is_file():
            try:
                defaults.update({k: v for k, v in _parse_yaml_simple(f).items() if not isinstance(v, str) or "{{" not in v})
            except yaml.YAMLError:
                pass
    return defaults


# alterId is hardcoded in ansible/roles/vpn/templates/v2ray/config.json.j2
# (line: "alterId": 64). Keep this in lockstep if that template changes.
DEFAULT_ALTER_ID = 64
DEFAULT_WS_PATH = "/v2ray"


def build_vmess_payload(domain: str, uuid: str, remark: str, ws_path: str, alter_id: int) -> dict:
    return {
        "v": "2",
        "ps": remark,
        "add": domain,
        "port": "443",
        "id": uuid,
        "aid": str(alter_id),
        "scy": "auto",
        "net": "ws",
        "type": "none",
        "host": domain,
        "path": ws_path,
        "tls": "tls",
        "sni": domain,
    }


def vmess_url(payload: dict) -> str:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return "vmess://" + base64.b64encode(raw).decode("ascii")


def clash_proxy(domain: str, uuid: str, remark: str, ws_path: str, alter_id: int) -> dict:
    return {
        "name": remark,
        "type": "vmess",
        "server": domain,
        "port": 443,
        "uuid": uuid,
        "alterId": alter_id,
        "cipher": "auto",
        "udp": False,
        "tls": True,
        "skip-cert-verify": False,
        "servername": domain,
        "network": "ws",
        "ws-opts": {"path": ws_path, "headers": {"Host": domain}},
    }


def human_readable(payload: dict, url: str) -> str:
    return (
        "# V2Ray / VMess client config\n"
        "\n"
        "| Field | Value |\n"
        "|---|---|\n"
        f"| Remark | `{payload['ps']}` |\n"
        f"| Address (add) | `{payload['add']}` |\n"
        f"| Port | `{payload['port']}` |\n"
        f"| UUID (id) | `{payload['id']}` |\n"
        f"| AlterId (aid) | `{payload['aid']}` |\n"
        f"| Security (scy) | `{payload['scy']}` |\n"
        f"| Network (net) | `{payload['net']}` |\n"
        f"| WS Host | `{payload['host']}` |\n"
        f"| WS Path | `{payload['path']}` |\n"
        f"| TLS | `{payload['tls']}` |\n"
        f"| SNI | `{payload['sni']}` |\n"
        "\n"
        "## One-liner (vmess://)\n"
        "\n"
        "```\n"
        f"{url}\n"
        "```\n"
        "\n"
        "## Notes\n"
        "\n"
        "- Paste the `vmess://` URL into Shadowrocket / v2rayN / v2rayNG via "
        "\"Import from clipboard\".\n"
        "- Or scan `qr.png` with Shadowrocket (\"Scan from album\").\n"
        "- For Clash / Clash Meta / Mihomo, merge `clash.yaml` into your config's `proxies:` list.\n"
    )


def ascii_qr(url: str) -> str:
    q = qrcode.QRCode(border=1, error_correction=qrcode.constants.ERROR_CORRECT_L)
    q.add_data(url)
    q.make(fit=True)
    import io

    buf = io.StringIO()
    q.print_ascii(out=buf, invert=True)
    return buf.getvalue()


def write_png_qr(url: str, path: Path) -> None:
    img = qrcode.make(url, image_factory=qrcode.image.pil.PilImage, box_size=10, border=2)
    img.save(path)


def _slug(s: str) -> str:
    return re.sub(r"[^a-zA-Z0-9._-]+", "-", s).strip("-") or "vpn"


def _state_file_for(rg: str | None) -> Path | None:
    """Return the state file (vms/<rg>.json or last-vm.json) matching rg, if any."""
    if rg:
        candidate = VMS_DIR / f"{rg}.json"
        if candidate.is_file():
            return candidate
    if LEGACY_LAST_VM.is_file():
        try:
            data = json.loads(LEGACY_LAST_VM.read_text())
            if rg is None or data.get("rg") == rg:
                return LEGACY_LAST_VM
        except json.JSONDecodeError:
            return None
    return None


def resolve_remark(explicit: str | None, rg: str | None) -> str:
    if explicit:
        return explicit
    state_file = _state_file_for(rg)
    if state_file is not None:
        try:
            data = json.loads(state_file.read_text())
            fqdn = data.get("fqdn", "")
            if fqdn:
                return _slug(fqdn.split(".")[0])
        except json.JSONDecodeError:
            pass
    return "vpn"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0] if __doc__ else "")
    p.add_argument("--rg", default=None,
                   help="Resource group to target (required when >1 VM is tracked; also accepts RG= env var).")
    p.add_argument("--remark", default=None, help="Friendly name shown in the client (default: DNS short name)")
    p.add_argument("--out", default=None, help="Output directory (default: out/client, or out/client/<rg>/ when --rg is set)")
    p.add_argument("--ws-path", default=None, help=f"Override WebSocket path (default: {DEFAULT_WS_PATH})")
    p.add_argument("--alter-id", type=int, default=None, help=f"Override alterId (default: {DEFAULT_ALTER_ID})")
    args = p.parse_args()

    rg = resolve_target_rg(args.rg)

    vault = read_vault(rg)
    defaults = read_non_secret_defaults()

    domain: str = vault["vault_domain"]
    uuid: str = vault["vault_v2ray_uuid"]
    ws_path: str = args.ws_path or defaults.get("v2ray_ws_path") or DEFAULT_WS_PATH
    alter_id: int = args.alter_id if args.alter_id is not None else DEFAULT_ALTER_ID

    remark = resolve_remark(args.remark, rg)

    # Namespace outputs per-RG when we have one, so running az-client across
    # multiple VMs doesn't overwrite the previous set of configs.
    if args.out is not None:
        out_dir = Path(args.out)
    elif rg and len(_list_tracked_rgs()) > 1:
        out_dir = OUT_DEFAULT / rg
    else:
        out_dir = OUT_DEFAULT

    payload = build_vmess_payload(domain, uuid, remark, ws_path, alter_id)
    url = vmess_url(payload)
    clash = clash_proxy(domain, uuid, remark, ws_path, alter_id)
    human = human_readable(payload, url)

    out_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / "vmess.txt").write_text(url + "\n")
    (out_dir / "config.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    with (out_dir / "clash.yaml").open("w") as fh:
        yaml.safe_dump({"proxies": [clash]}, fh, allow_unicode=True, sort_keys=False)
    (out_dir / "human.md").write_text(human)
    write_png_qr(url, out_dir / "qr.png")

    # Tighten perms — these files embed the UUID.
    for name in ("vmess.txt", "config.json", "clash.yaml", "human.md", "qr.png"):
        (out_dir / name).chmod(0o600)

    log(f"Wrote {out_dir.relative_to(REPO_ROOT) if out_dir.is_absolute() else out_dir}/")
    log("  vmess.txt  config.json  clash.yaml  human.md  qr.png")

    print()
    print(human)
    print("## QR (ASCII, scan with Shadowrocket etc.)")
    print()
    print(ascii_qr(url))

    return 0


if __name__ == "__main__":
    sys.exit(main())
