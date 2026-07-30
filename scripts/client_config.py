#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML>=6", "qrcode[pil]>=7.4"]
# ///
"""
Emit client configs for this server in every common format.

Which protocol it emits follows `vpn_protocol` in ansible/group_vars/all.yml,
so the client configs can't drift from what is actually deployed:

    reality   → VLESS + XTLS-Vision + REALITY   (default)
    vmess_ws  → VMess over WebSocket + TLS      (legacy)
    both      → both sets, side by side

Reads domain + UUID + REALITY key material from the per-host ansible-vault–
encrypted vault (`ansible/host_vars/<rg>/vault.yml`), plus the non-secret knobs
(protocol, WebSocket path, borrowed SNI, fingerprint) from
ansible/group_vars/all.yml. Falls back to the legacy single-host vault at
`ansible/group_vars/vpn/vault.yml` when no per-host layout is present.

With multiple tracked VMs, you must pass `<resource-group>` positionally
(or `--rg <rg>`, or set `RG=<rg>`). With exactly one tracked VM, defaults
to that one.

Writes to out/client/ (or out/client/<rg>/ when an RG is passed):
    REALITY:
      vless.txt         single-line vless://… URL (v2rayN / v2rayNG / Shadowrocket)
      xray-client.json  full Xray outbound config (also what `just verify-proxy` runs)
      clash.yaml        mihomo VLESS proxy entry with reality-opts
      qr.png            PNG QR of the vless:// link
    VMess (legacy modes):
      vmess.txt         single-line vmess://base64(json) URL
      config.json       pretty inner JSON
      clash-vmess.yaml  mihomo VMess proxy entry (clash.yaml when VMess is the only mode)
      qr-vmess.png      PNG QR of the vmess:// link (qr.png when VMess is the only mode)
    human.md            human-readable field table for whatever was emitted

Also prints the human-readable block and an ASCII QR in the terminal.

Usage:
    scripts/client_config.py
    scripts/client_config.py vpn-test-you-1234          # positional RG
    scripts/client_config.py --rg vpn-test-you-1234     # long flag
    RG=vpn-test-you-1234 scripts/client_config.py       # env var
    scripts/client_config.py --remark 'my-tokyo-node'
    scripts/client_config.py --out custom/dir
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
import urllib.parse
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

# Fallbacks used only when group_vars/all.yml can't be read. Keep in lockstep
# with that file.
DEFAULT_PROTOCOL = "reality"
DEFAULT_WS_PATH = "/v2ray"
DEFAULT_SNI = "www.apple.com"
DEFAULT_FINGERPRINT = "chrome"
DEFAULT_VMESS_WS_PORT = 2053


def die(msg: str) -> None:
    print(f"[client-config] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg: str) -> None:
    print(f"[client-config] {msg}", file=sys.stderr)


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
      - positional <rg>      → use it (error if not tracked)
      - --rg <name>          → same as positional
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
        log("Multiple VMs tracked — pass <resource-group> (positional, --rg, or RG=<rg>):")
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


def read_vault(rg: str | None, protocol: str) -> dict:
    """Prefer per-host vault under host_vars/<rg>/vault.yml; fall back to the
    legacy single-host group vault so older setups still work."""
    if not shutil.which("ansible-vault"):
        die("ansible-vault not on PATH — install ansible-core")

    required = ["vault_domain", "vault_v2ray_uuid"]
    if protocol in ("reality", "both"):
        required += ["vault_reality_public_key", "vault_reality_short_id"]

    vault_pass = resolve_vault_pass_file()
    candidates: list[Path] = []
    if rg:
        candidates.append(HOST_VARS_DIR / rg / "vault.yml")
    candidates.append(LEGACY_GROUP_VAULT)

    for vault_file in candidates:
        if vault_file.is_file():
            data = _vault_view(vault_file, vault_pass)
            missing = [k for k in required if not data.get(k)]
            if missing:
                die(
                    f"{vault_file} is missing: {', '.join(missing)}\n"
                    f"  vpn_protocol={protocol} needs REALITY key material. Generate it with\n"
                    f"    scripts/reality_keys.py --format vault-yaml\n"
                    f"  and add it via `just vault-edit{' ' + rg if rg else ''}`."
                )
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
    """Pull the client-visible knobs (protocol, ws path, borrowed SNI, …) from
    the ansible defaults so client config stays in lockstep with server config.

    Values that are still Jinja expressions (letsencrypt_enabled,
    firewall_allowed_tcp) are dropped — nothing here needs them, and evaluating
    them would mean dragging in ansible.
    """
    defaults = {}
    for f in (ALL_VARS, VPN_DEFAULTS):
        if f.is_file():
            try:
                defaults.update({
                    k: v for k, v in _parse_yaml_simple(f).items()
                    if not isinstance(v, str) or "{{" not in v
                })
            except yaml.YAMLError:
                pass
    return defaults


# --------------------------------------------------------------------------
# VLESS + XTLS-Vision + REALITY
# --------------------------------------------------------------------------

def vless_url(domain: str, uuid: str, remark: str, sni: str, public_key: str,
              short_id: str, fingerprint: str) -> str:
    """Standard vless:// share link (v2rayN / v2rayNG / Shadowrocket).

    `domain` stays the FQDN rather than the bare IP on purpose: REALITY sends
    the borrowed `sni`, not this hostname, so keeping the FQDN here means
    `just az-rotate-ip` can swap the public IP without invalidating any client.
    """
    query = urllib.parse.urlencode({
        "encryption": "none",
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "sni": sni,
        "fp": fingerprint,
        "pbk": public_key,
        "sid": short_id,
        "type": "tcp",
    })
    return f"vless://{uuid}@{domain}:443?{query}#{urllib.parse.quote(remark)}"


def vless_clash_proxy(domain: str, uuid: str, remark: str, sni: str,
                      public_key: str, short_id: str, fingerprint: str) -> dict:
    """mihomo / Clash.Meta proxy entry. Shape matches
    clients/mihomo-docker/config.example.yaml."""
    return {
        "name": remark,
        "type": "vless",
        "server": domain,
        "port": 443,
        "uuid": uuid,
        "network": "tcp",
        "udp": True,
        "tls": True,
        "flow": "xtls-rprx-vision",
        "servername": sni,
        "reality-opts": {"public-key": public_key, "short-id": short_id},
        "client-fingerprint": fingerprint,
    }


def vless_xray_client(domain: str, uuid: str, sni: str, public_key: str,
                      short_id: str, fingerprint: str, socks_port: int = 10808) -> dict:
    """A complete Xray client config — importable into v2rayN, and what
    `just verify-proxy` feeds to a throwaway xray container to prove the tunnel
    actually carries traffic."""
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks",
                "port": socks_port,
                "listen": "0.0.0.0",
                "protocol": "socks",
                "settings": {"udp": True},
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": domain,
                            "port": 443,
                            "users": [
                                {
                                    "id": uuid,
                                    "encryption": "none",
                                    "flow": "xtls-rprx-vision",
                                }
                            ],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "serverName": sni,
                        "fingerprint": fingerprint,
                        "publicKey": public_key,
                        "shortId": short_id,
                        "spiderX": "",
                    },
                },
            }
        ],
    }


# --------------------------------------------------------------------------
# VMess over WebSocket (legacy modes)
# --------------------------------------------------------------------------

def build_vmess_payload(domain: str, uuid: str, remark: str, ws_path: str, port: int) -> dict:
    # aid is always "0": Xray-core speaks VMess AEAD only and rejects
    # alterId > 0 outright. Pre-migration clients pinned to alterId 64 must be
    # re-imported from this file.
    return {
        "v": "2",
        "ps": remark,
        "add": domain,
        "port": str(port),
        "id": uuid,
        "aid": "0",
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


def vmess_clash_proxy(domain: str, uuid: str, remark: str, ws_path: str, port: int) -> dict:
    return {
        "name": f"{remark}-vmess",
        "type": "vmess",
        "server": domain,
        "port": port,
        "uuid": uuid,
        "alterId": 0,
        "cipher": "auto",
        "udp": False,
        "tls": True,
        "skip-cert-verify": False,
        "servername": domain,
        "network": "ws",
        "ws-opts": {"path": ws_path, "headers": {"Host": domain}},
    }


# --------------------------------------------------------------------------

def human_readable(protocol: str, reality: dict | None, vmess: dict | None,
                   vless_link: str | None, vmess_link: str | None) -> str:
    out = [f"# Client config (vpn_protocol: `{protocol}`)", ""]

    if reality is not None:
        out += [
            "## VLESS + XTLS-Vision + REALITY",
            "",
            "| Field | Value |",
            "|---|---|",
            f"| Remark | `{reality['remark']}` |",
            f"| Address | `{reality['domain']}` |",
            "| Port | `443` |",
            f"| UUID | `{reality['uuid']}` |",
            "| Flow | `xtls-rprx-vision` |",
            "| Network | `tcp` |",
            "| Security | `reality` |",
            f"| SNI / servername | `{reality['sni']}` |",
            f"| Public key (pbk) | `{reality['public_key']}` |",
            f"| Short ID (sid) | `{reality['short_id']}` |",
            f"| Fingerprint (fp) | `{reality['fingerprint']}` |",
            "",
            "```",
            f"{vless_link}",
            "```",
            "",
            "> The SNI is **borrowed** — it names the site REALITY impersonates and has",
            "> nothing to do with the address you connect to. Leave `Address` as the",
            "> FQDN so rotating the VPS public IP doesn't invalidate this config.",
            "",
        ]

    if vmess is not None:
        out += [
            "## VMess over WebSocket + TLS (legacy)",
            "",
            "| Field | Value |",
            "|---|---|",
            f"| Remark | `{vmess['ps']}` |",
            f"| Address (add) | `{vmess['add']}` |",
            f"| Port | `{vmess['port']}` |",
            f"| UUID (id) | `{vmess['id']}` |",
            f"| AlterId (aid) | `{vmess['aid']}` |",
            f"| Security (scy) | `{vmess['scy']}` |",
            f"| Network (net) | `{vmess['net']}` |",
            f"| WS Host | `{vmess['host']}` |",
            f"| WS Path | `{vmess['path']}` |",
            f"| TLS | `{vmess['tls']}` |",
            f"| SNI | `{vmess['sni']}` |",
            "",
            "```",
            f"{vmess_link}",
            "```",
            "",
            "> **AlterId must be 0.** Xray-core dropped legacy non-AEAD VMess, so a client",
            "> still configured with `alterId: 64` cannot connect at all.",
            "",
        ]

    out += [
        "## Notes",
        "",
        "- Paste the URL into Shadowrocket / v2rayN / v2rayNG via \"Import from clipboard\",",
        "  or scan the matching `qr*.png` (\"Scan from album\").",
        "- For Clash / mihomo, merge `clash.yaml` into your config's `proxies:` list.",
        "- `just verify-proxy` runs `xray-client.json` through a throwaway container to",
        "  confirm traffic really flows, not just that the handshake looks right.",
        "",
    ]
    return "\n".join(out)


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
    p.add_argument("rg_positional", nargs="?", default=None, metavar="RG",
                   help="Resource group to target (positional; same as --rg).")
    p.add_argument("--rg", default=None,
                   help="Resource group to target (required when >1 VM is tracked; also accepts RG= env var).")
    p.add_argument("--remark", default=None, help="Friendly name shown in the client (default: DNS short name)")
    p.add_argument("--out", default=None, help="Output directory (default: out/client, or out/client/<rg>/ when an RG is selected)")
    p.add_argument("--protocol", choices=["reality", "vmess_ws", "both"], default=None,
                   help="Override the protocol (default: vpn_protocol from ansible/group_vars/all.yml)")
    p.add_argument("--ws-path", default=None, help=f"Override WebSocket path (default: {DEFAULT_WS_PATH})")
    args = p.parse_args()

    if args.rg_positional and args.rg and args.rg_positional != args.rg:
        die(f"conflicting resource groups: positional={args.rg_positional!r} vs --rg={args.rg!r}")
    rg = resolve_target_rg(args.rg_positional or args.rg)

    defaults = read_non_secret_defaults()
    protocol: str = args.protocol or defaults.get("vpn_protocol") or DEFAULT_PROTOCOL

    vault = read_vault(rg, protocol)

    domain: str = vault["vault_domain"]
    uuid: str = vault["vault_v2ray_uuid"]
    ws_path: str = args.ws_path or defaults.get("v2ray_ws_path") or DEFAULT_WS_PATH
    fingerprint: str = defaults.get("reality_client_fingerprint") or DEFAULT_FINGERPRINT
    server_names = defaults.get("reality_server_names") or [DEFAULT_SNI]
    sni: str = server_names[0]
    # In `both` mode 443 belongs to REALITY, so the WS listener moved.
    vmess_port: int = (
        defaults.get("vmess_ws_port", DEFAULT_VMESS_WS_PORT) if protocol == "both" else 443
    )

    remark = resolve_remark(args.remark, rg)

    # Namespace outputs per-RG when we have one, so running az-client across
    # multiple VMs doesn't overwrite the previous set of configs.
    if args.out is not None:
        out_dir = Path(args.out)
    elif rg and len(_list_tracked_rgs()) > 1:
        out_dir = OUT_DEFAULT / rg
    else:
        out_dir = OUT_DEFAULT

    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    reality_fields = None
    vmess_payload = None
    vless_link = None
    vmess_link = None

    if protocol in ("reality", "both"):
        public_key = vault["vault_reality_public_key"]
        short_id = vault["vault_reality_short_id"]
        reality_fields = {
            "remark": remark, "domain": domain, "uuid": uuid, "sni": sni,
            "public_key": public_key, "short_id": short_id, "fingerprint": fingerprint,
        }
        vless_link = vless_url(domain, uuid, remark, sni, public_key, short_id, fingerprint)
        clash = vless_clash_proxy(domain, uuid, remark, sni, public_key, short_id, fingerprint)
        xray_client = vless_xray_client(domain, uuid, sni, public_key, short_id, fingerprint)

        (out_dir / "vless.txt").write_text(vless_link + "\n")
        (out_dir / "xray-client.json").write_text(json.dumps(xray_client, indent=2) + "\n")
        with (out_dir / "clash.yaml").open("w") as fh:
            yaml.safe_dump({"proxies": [clash]}, fh, allow_unicode=True, sort_keys=False)
        write_png_qr(vless_link, out_dir / "qr.png")
        written += ["vless.txt", "xray-client.json", "clash.yaml", "qr.png"]

    if protocol in ("vmess_ws", "both"):
        vmess_payload = build_vmess_payload(domain, uuid, remark, ws_path, vmess_port)
        vmess_link = vmess_url(vmess_payload)
        vmess_clash = vmess_clash_proxy(domain, uuid, remark, ws_path, vmess_port)

        (out_dir / "vmess.txt").write_text(vmess_link + "\n")
        (out_dir / "config.json").write_text(
            json.dumps(vmess_payload, indent=2, ensure_ascii=False) + "\n"
        )
        clash_name = "clash-vmess.yaml" if protocol == "both" else "clash.yaml"
        with (out_dir / clash_name).open("w") as fh:
            yaml.safe_dump({"proxies": [vmess_clash]}, fh, allow_unicode=True, sort_keys=False)
        qr_name = "qr-vmess.png" if protocol == "both" else "qr.png"
        write_png_qr(vmess_link, out_dir / qr_name)
        written += ["vmess.txt", "config.json", clash_name, qr_name]

    human = human_readable(protocol, reality_fields, vmess_payload, vless_link, vmess_link)
    (out_dir / "human.md").write_text(human)
    written.append("human.md")

    # Tighten perms — these files embed the UUID.
    for name in dict.fromkeys(written):
        (out_dir / name).chmod(0o600)

    log(f"Wrote {out_dir.relative_to(REPO_ROOT) if out_dir.is_absolute() else out_dir}/")
    log("  " + "  ".join(dict.fromkeys(written)))

    print()
    print(human)
    primary = vless_link or vmess_link
    if primary:
        print("## QR (ASCII, scan with Shadowrocket etc.)")
        print()
        print(ascii_qr(primary))

    return 0


if __name__ == "__main__":
    sys.exit(main())
