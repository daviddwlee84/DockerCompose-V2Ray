---
name: opencode feedback fixes
overview: "Address OpenCode's review feedback on the IP-rotation + multi-host PR: two must-fix bugs in `az_rotate_ip.sh`, three UX/correctness should-fixes in the `Justfile` + docs + script-arg handling, and two nice-to-haves (a `just az-list` recipe and a migration note)."
todos:
  - id: fix-pip-casing
    content: Change --remove PublicIpAddress to publicIPAddress in az_rotate_ip.sh L178 with explanatory comment
    status: completed
  - id: fix-legacy-mirror
    content: After rotation state-file write, mirror STATE_FILE to last-vm.json when legacy RG matches
    status: completed
  - id: fix-vault-recipes
    content: Rework just vault-edit / vault-encrypt to accept <rg> and route to host_vars/<rg>/vault.yml
    status: completed
  - id: unify-rg-args
    content: Add positional + --rg + RG= support across vmess_client.py, az_rotate_ip.sh, az_down.sh, verify.sh
    status: completed
  - id: update-docs-args
    content: Update MULTI-HOST.md examples to use positional <rg> consistently
    status: completed
  - id: add-az-list
    content: Add just az-list recipe printing rg/fqdn/public_ip/created_at table with * marking vms/current
    status: completed
  - id: add-migration-note
    content: Document the legacy group-vault migration recommendation in MULTI-HOST.md + vault.yml.example header
    status: completed
  - id: verify
    content: Re-run the offline dual-VM dry-run covering all new behaviors
    status: completed
  - id: todo-1776822689544-ghyyccz7h
    content: git commit with specstory chat history
    status: pending
isProject: false
---

## Tier 1 — Must-fix (before push)

### 1. `--remove PublicIpAddress` casing in [scripts/az_rotate_ip.sh](scripts/az_rotate_ip.sh)

At L174-179, Azure CLI's generic `--remove` matches JSON-body field names. The NIC ip-config body uses `publicIPAddress` (lowerCamel with capital `IP`), which is also what MS docs example. `PublicIpAddress` (capital P, lowercase `ip`) only works by accident if the CLI normalizes casing, and has been flaky in practice. Two safe options:

- **Option A (minimal):** change `--remove PublicIpAddress` → `--remove publicIPAddress`, with a one-line comment tying it to the Azure ARM JSON schema.
- **Option B (documented):** replace `--remove` with the documented detach idiom `--public-ip-address ""`. Cleaner but slightly different semantics (it sets to empty instead of deleting the key).

Plan: go with **Option A**. Add an inline comment at L178 explaining the casing:

```bash
# Azure CLI's --remove matches JSON-body field names (lowerCamelCase with
# "IP" uppercase, per ARM schema). PublicIpAddress happened to work on
# some az-cli versions but publicIPAddress is the canonical one.
--remove publicIPAddress \
```

Keep an eye on this during first real-Azure run; if it fails, fall back to Option B.

### 2. Sync legacy `last-vm.json` mirror after rotation in [scripts/az_rotate_ip.sh](scripts/az_rotate_ip.sh)

Currently L215-220 only writes `$STATE_FILE`. If that state file is `vms/<rg>.json` but `last-vm.json` is a mirror of the same RG (maintained by `az_up.sh:256`), rotation leaves stale `public_ip` in the legacy mirror.

Fix: right after `mv "$TMP" "$STATE_FILE"`, mirror back when applicable — matching [scripts/az_up.sh](scripts/az_up.sh) L253-256:

```bash
# Keep the legacy mirror in sync if it tracks the rotated VM.
if [ "$STATE_FILE" != "$LEGACY_LAST_VM" ] && [ -f "$LEGACY_LAST_VM" ]; then
    legacy_rg=$(jq -r '.rg // empty' "$LEGACY_LAST_VM" 2>/dev/null || true)
    if [ "$legacy_rg" = "$AZ_RG" ]; then
        cp "$STATE_FILE" "$LEGACY_LAST_VM"
        log "Also updated legacy $LEGACY_LAST_VM (mirror of $AZ_RG)."
    fi
fi
```

---

## Tier 2 — Should-fix (UX / doc correctness)

### 3. `just vault-edit` / `just vault-encrypt` point at the legacy path

[Justfile](Justfile) L104-110 still edit `group_vars/vpn/vault.yml`, which in the multi-host flow is a non-operational file. Editing it silently does nothing because Ansible reads the per-host vault under `host_vars/<rg>/`.

Fix: take an optional positional `<rg>`, route correctly, and emit a loud deprecation hint when falling back:

```
# Edit a host's encrypted vault. Pass <rg> when running multi-host.
vault-edit *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ansible_dir}}
    RG="${1:-${RG:-}}"
    if [ -n "$RG" ] && [ -f "host_vars/$RG/vault.yml" ]; then
        exec ansible-vault edit "host_vars/$RG/vault.yml"
    fi
    # ... list host_vars/* and refuse if >1 exists, else fall back to legacy
    # group vault with a one-line deprecation warning.
```

Same shape for `vault-encrypt`. Update the README / MULTI-HOST hint to mention `just vault-edit <rg>`.

### 4. ~~`az-cycle` readlink~~ — withdrawn by OpenCode, no change.

### 5. Unify positional + `--rg` + `RG=` across all per-host scripts

Today:

- [scripts/az_rotate_ip.sh](scripts/az_rotate_ip.sh): positional + `AZ_RG=`, no `--rg`, no `RG=`.
- [scripts/az_down.sh](scripts/az_down.sh): positional + `AZ_RG=`, no `--rg`, no `RG=`.
- [scripts/vmess_client.py](scripts/vmess_client.py): `--rg` + `RG=`, no positional.
- [scripts/verify.sh](scripts/verify.sh): `RG=` + `DOMAIN=`, no positional, no `--rg`.

Make all four accept `<rg>` positional, `--rg <rg>`, and `RG=<rg>`, in that precedence order:

- `vmess_client.py` `main()` L337-344: add `p.add_argument("rg_positional", nargs="?", default=None)`, then `rg = args.rg_positional or args.rg or os.environ.get("RG")`.
- `az_rotate_ip.sh` L51: extend the arg-parse loop to recognize `--rg <val>` and keep `RG=<rg>` as an alias for `AZ_RG`.
- `az_down.sh` L28-42: same treatment — add `--rg` and read `RG` env.
- `verify.sh` L22-30: add a positional-arg parse before the `RG=` block.

Update [docs/MULTI-HOST.md](docs/MULTI-HOST.md) L60-63 examples to show the shortest form consistently:

```bash
just az-client <rg>
just verify <rg>
just az-rotate-ip <rg>
just az-down <rg>
```

Mention in a one-liner that `--rg <rg>` and `RG=<rg>` also work for interop with wrapper scripts.

---

## Tier 3 — Nice-to-have

### 6. Add `just az-list`

Small bash recipe in [Justfile](Justfile), inserted next to the other `az-*` recipes. Prints a column-aligned table of `<rg>  <fqdn>  <public_ip>  <created_at>` by scanning `.secrets/azure/vms/*.json`. About 25 lines; reuses the `jq` pattern already in `az_down.sh` L55-58.

Bonus: marks the row corresponding to `vms/current` with a `*` prefix so the operator can see the default selection at a glance.

### 7. Migration note in [docs/MULTI-HOST.md](docs/MULTI-HOST.md)

Add a short section (below "State layout", above "Typical flow"):

> **Migration note (single → multi-host):** once every VM has its own
> `ansible/host_vars/<rg>/vault.yml`, the legacy group vault at
> `ansible/group_vars/vpn/vault.yml` is no longer read for anything, but
> Ansible still attempts to unlock it on every play if it's encrypted —
> one wasted vault decryption per `just deploy`. Recommended: move it
> aside with `git mv ansible/group_vars/vpn/vault.yml legacy/` (or
> delete it) after the first successful multi-host deploy.

Also add one sentence to [ansible/group_vars/vpn/vault.yml.example](ansible/group_vars/vpn/vault.yml.example) header mentioning the migration recommendation.

---

## Verification

- `just --list` and shellcheck each edited script locally.
- Repeat the offline dual-VM dry-run that validated the original PR:
  1. Seed two fake `vms/<rg>.json` entries (or reuse whatever harness worked before).
  2. Run `just az-list` — expect both rows, `*` next to the one `vms/current` points at.
  3. Run `just vault-edit rg-that-doesnt-exist` — expect a helpful error listing the real host_vars dirs.
  4. Run `just az-rotate-ip <rg>` with Azure stubbed: verify the `last-vm.json` mirror is updated when the rotated RG matches the mirrored one, and left alone otherwise.
  5. Confirm all four scripts accept the same three forms: `<rg>`, `--rg <rg>`, `RG=<rg> just …`.
- Real-Azure smoke test of `just az-rotate-ip <rg>`: watch L174-179 for the casing issue described in item 1; fall back to `--public-ip-address ""` only if `--remove publicIPAddress` errors.

## Out of scope

- Anything not in OpenCode's feedback (custom-domain rotation, fleet management, UUID rotation UX, etc.).
- Changing Ansible variable precedence or vault storage layout — the fix in item 7 is documentation-only.
- Removing the `last-vm.json` legacy mirror. That's a separate PR after the multi-host flow has a full release cycle of bake-in.
