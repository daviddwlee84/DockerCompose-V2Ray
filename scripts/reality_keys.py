#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["cryptography>=42"]
# ///
"""
Generate REALITY key material: an X25519 keypair plus a short ID.

Reimplements `xray x25519` rather than shelling out to it, so the laptop needs
no xray binary and no docker pull. The reimplementation is exact — see
Xray-core main/commands/all/curve25519.go:

    privateKey[0]  &= 248
    privateKey[31] &= 127
    privateKey[31] |= 64
    publicKey = X25519(privateKey).PublicKey()
    both printed with base64.RawURLEncoding

That clamping is the part worth being careful about. Xray prints the CLAMPED
private key, and REALITY's handshake derives the public key from whatever you
put in the config. Emit an unclamped key and the server's public key silently
stops matching the one you handed clients: Xray starts fine, the TCP connection
establishes, and every handshake fails in a way indistinguishable from being
blocked. `--verify-with-docker` re-derives the pair through the real xray
binary and diffs, so the encoding can be proven rather than assumed.

Usage:
    scripts/reality_keys.py                     # human-readable block
    scripts/reality_keys.py --format vault-yaml # paste-ready vault_* lines
    scripts/reality_keys.py --format json
    scripts/reality_keys.py --verify-with-docker
"""
from __future__ import annotations

import argparse
import base64
import json
import secrets
import shutil
import subprocess
import sys

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
)

# Must match ansible/group_vars/all.yml xray_image so the cross-check runs
# against the same core that will serve traffic.
XRAY_IMAGE = "ghcr.io/xtls/xray-core:26.3.27"


def die(msg: str) -> None:
    print(f"[reality-keys] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def b64(raw: bytes) -> str:
    """base64.RawURLEncoding — URL alphabet, no padding."""
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def clamp(raw: bytes) -> bytes:
    k = bytearray(raw)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return bytes(k)


def keypair(seed: bytes | None = None) -> tuple[str, str]:
    """Return (private_key, public_key) in Xray's base64 RawURLEncoding."""
    priv_raw = clamp(seed if seed is not None else secrets.token_bytes(32))
    priv = X25519PrivateKey.from_private_bytes(priv_raw)
    pub_raw = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    # Round-trip the private bytes through the library rather than trusting our
    # own buffer, so any future clamping change shows up here.
    priv_out = priv.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    return b64(priv_out), b64(pub_raw)


def short_id(num_bytes: int = 4) -> str:
    """Hex string, even length, max 16 chars (Xray shortIds constraint)."""
    return secrets.token_hex(num_bytes)


def verify_with_docker(private_key: str, public_key: str) -> None:
    """Re-derive the pair with the real xray binary and diff against ours."""
    if not shutil.which("docker"):
        die("docker not on PATH — cannot cross-check against the xray binary")

    proc = subprocess.run(
        ["docker", "run", "--rm", XRAY_IMAGE, "x25519", "-i", private_key],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        die(f"`docker run {XRAY_IMAGE} x25519` failed")

    fields: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fields[k.strip().lower()] = v.strip()

    # Field label has drifted across releases ("PublicKey", then
    # "Password (PublicKey)"), so match on substring rather than exact key.
    xray_priv = next((v for k, v in fields.items() if "privatekey" in k.replace(" ", "")), None)
    xray_pub = next((v for k, v in fields.items() if "publickey" in k.replace(" ", "")), None)
    if not xray_priv or not xray_pub:
        die(f"could not parse xray output:\n{proc.stdout}")

    ok = True
    if xray_priv != private_key:
        print(f"  MISMATCH private: ours={private_key} xray={xray_priv}", file=sys.stderr)
        ok = False
    if xray_pub != public_key:
        print(f"  MISMATCH public:  ours={public_key} xray={xray_pub}", file=sys.stderr)
        ok = False
    if not ok:
        die("generated key material does not match xray — do NOT deploy these keys")
    print(f"[reality-keys] verified against {XRAY_IMAGE}: private + public key match", file=sys.stderr)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0] if __doc__ else "")
    p.add_argument("--format", choices=["human", "vault-yaml", "json"], default="human")
    p.add_argument("--short-id-bytes", type=int, default=4,
                   help="Short ID length in bytes; hex-encoded output is twice this (max 8).")
    p.add_argument("--verify-with-docker", action="store_true",
                   help=f"Cross-check the keypair against `{XRAY_IMAGE} x25519`.")
    args = p.parse_args()

    if not 1 <= args.short_id_bytes <= 8:
        die("--short-id-bytes must be between 1 and 8 (Xray caps shortIds at 16 hex chars)")

    priv, pub = keypair()
    sid = short_id(args.short_id_bytes)

    if args.verify_with_docker:
        verify_with_docker(priv, pub)

    if args.format == "json":
        print(json.dumps({"private_key": priv, "public_key": pub, "short_id": sid}, indent=2))
    elif args.format == "vault-yaml":
        print(f'vault_reality_private_key: "{priv}"')
        print(f'vault_reality_public_key: "{pub}"')
        print(f'vault_reality_short_id: "{sid}"')
    else:
        print("REALITY key material")
        print()
        print(f"  private key (server, keep secret) : {priv}")
        print(f"  public key  (clients)             : {pub}")
        print(f"  short ID    (clients)             : {sid}")
        print()
        print("Add to this host's vault (just vault-edit <rg>):")
        print()
        print(f'  vault_reality_private_key: "{priv}"')
        print(f'  vault_reality_public_key: "{pub}"')
        print(f'  vault_reality_short_id: "{sid}"')
        print()
        print("`just az-configure` writes these automatically for Azure throwaway VMs.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
