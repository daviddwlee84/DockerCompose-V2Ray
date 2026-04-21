#!/bin/bash
set -euo pipefail

curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker

echo
echo "Docker installed (rootful). Log out and back in for group membership to take effect."
echo "Verify with: docker run --rm hello-world"
