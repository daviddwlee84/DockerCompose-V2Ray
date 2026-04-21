#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML>=6", "qrcode[pil]>=7.4"]
# ///
"""
Emit V2Ray / VMess client configs in every common format.

Reads domain + UUID from the ansible-vault–encrypted vault, plus the non-secret
defaults (WebSocket path, alterId) from ansible/group_vars/all.yml and the
vpn role defaults.

Writes to out/client/:
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
VAULT_FILE = REPO_ROOT / "ansible" / "group_vars" / "vpn" / "vault.yml"
ALL_VARS = REPO_ROOT / "ansible" / "group_vars" / "all.yml"
VPN_DEFAULTS = REPO_ROOT / "ansible" / "roles" / "vpn" / "defaults" / "main.yml"
LAST_VM = REPO_ROOT / ".secrets" / "azure" / "last-vm.json"
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


def read_vault() -> dict:
    if not VAULT_FILE.is_file():
        die(f"{VAULT_FILE} not found — run `just az-configure` first")

    if not shutil.which("ansible-vault"):
        die("ansible-vault not on PATH — install ansible-core")

    cmd = ["ansible-vault", "view", str(VAULT_FILE)]
    vault_pass = resolve_vault_pass_file()
    if vault_pass:
        cmd[1:1] = ["--vault-password-file", str(vault_pass)]
        # Insert after 'ansible-vault', before 'view'.
        cmd = ["ansible-vault", "view", "--vault-password-file", str(vault_pass), str(VAULT_FILE)]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        die("ansible-vault view failed — ensure vault password is accessible")
    data = yaml.safe_load(result.stdout) or {}
    for key in ("vault_domain", "vault_v2ray_uuid"):
        if not data.get(key):
            die(f"vault is missing {key}")
    return data


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


def resolve_remark(explicit: str | None) -> str:
    if explicit:
        return explicit
    # Best effort: use the short DNS label from last-vm.json if available.
    if LAST_VM.is_file():
        try:
            data = json.loads(LAST_VM.read_text())
            fqdn = data.get("fqdn", "")
            if fqdn:
                return _slug(fqdn.split(".")[0])
        except json.JSONDecodeError:
            pass
    return "vpn"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0] if __doc__ else "")
    p.add_argument("--remark", default=None, help="Friendly name shown in the client (default: DNS short name)")
    p.add_argument("--out", default=str(OUT_DEFAULT), help="Output directory (default: out/client)")
    p.add_argument("--ws-path", default=None, help=f"Override WebSocket path (default: {DEFAULT_WS_PATH})")
    p.add_argument("--alter-id", type=int, default=None, help=f"Override alterId (default: {DEFAULT_ALTER_ID})")
    args = p.parse_args()

    vault = read_vault()
    defaults = read_non_secret_defaults()

    domain: str = vault["vault_domain"]
    uuid: str = vault["vault_v2ray_uuid"]
    ws_path: str = args.ws_path or defaults.get("v2ray_ws_path") or DEFAULT_WS_PATH
    alter_id: int = args.alter_id if args.alter_id is not None else DEFAULT_ALTER_ID

    remark = resolve_remark(args.remark)

    payload = build_vmess_payload(domain, uuid, remark, ws_path, alter_id)
    url = vmess_url(payload)
    clash = clash_proxy(domain, uuid, remark, ws_path, alter_id)
    human = human_readable(payload, url)

    out_dir = Path(args.out)
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
