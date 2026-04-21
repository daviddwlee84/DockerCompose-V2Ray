# Legacy deploy flow (pre-IaC refactor)

Before the Ansible migration, DockerCompose-V2Ray deployed via a shell-script + Docker Compose flow. That flow is preserved at the [`pre-iac-refactor`](../../tree/pre-iac-refactor) git tag and the archived files under [`../legacy/`](../legacy/).

## When to use the legacy flow

- You need to redeploy **now** and PR 2 (Ansible) hasn't landed yet.
- You want to understand how the project worked before the refactor.
- You're debugging a discrepancy between old and new behavior.

## How it worked (recap)

1. **Create VPS** (Azure VM, Ubuntu 20.04, ports 80 and 443 open; DNS pointed at the public IP).
2. **Install Docker**: `curl -fsSL https://get.docker.com | sudo sh` (the bundled `install_docker.sh` also tried rootless mode — that's the reason it's retired).
3. **Clone the repo** on the VPS.
4. **Edit `initial_https.sh`**: set `your_domain` and `your_email_address`.
5. **Run `./initial_https.sh`**: `sed`-substituted the values into `init-letsencrypt.sh` and `data/nginx/conf.d/v2ray.conf`, then bootstrapped Let's Encrypt via certbot.
6. **Edit `data/v2ray/config.json`**: change the hardcoded default UUID (`bae399d4-...`) to your own.
7. **`docker compose up --build`** to start Nginx + Certbot + V2Ray.

### Known footguns in the legacy flow

- The default UUID was copied across four tracked files; forgetting to rotate meant your deploy shared credentials with anyone else using the repo as-is.
- `initial_https.sh` edited tracked files in place via `sed`. Re-running was destructive; recovery was `git reset --hard`.
- `install_docker.sh` installed rootful Docker, *then* ran `dockerd-rootless-setuptool.sh install`. Rootless + privileged ports (80/443) without `CAP_NET_BIND_SERVICE` on `rootlesskit` = the `cannot expose privileged port 80` error documented in the README's troubleshooting section.
- `.gitignore` only excluded `.DS_Store`, so `data/certbot/` (real Let's Encrypt certs) and `logs/` were one `git add .` away from landing in a commit.

The new flow addresses each of these.

## Restoring the legacy flow

```bash
git fetch --tags
git checkout pre-iac-refactor
# Read the README at that tag and follow from section "### 1. Setup VPS".
```

Or browse the archived files directly under [`legacy/`](../legacy/):

- `legacy/scripts/` — the original `install_docker.sh`, `initial_https.sh`, `init-letsencrypt.sh`.
- `legacy/compose/` — `docker-compose.yml` and the no-TLS variant.
- `legacy/data/` — the original nginx and V2Ray configs with the hardcoded UUID and `your_domain` placeholder.
- `legacy/clients/`, `legacy/example/` — old client-side files.

These copies are functionally identical to the tag's contents but sit in-tree so they stay visible during code review. For history (who changed what and when), work from the tag.
