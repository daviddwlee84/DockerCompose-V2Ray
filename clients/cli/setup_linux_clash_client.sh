#!/bin/bash
wget https://github.com/Kuingsmile/clash-core/releases/download/1.18/clash-linux-386-v1.18.0.gz
gunzip clash-linux-386-v1.18.0.gz
chmod +x clash-linux-386-v1.18.0
sudo mv clash-linux-386-v1.18.0 /usr/local/bin/clash

# Run clash => will generate config at .config/clash
# /home/username/.config/clash
# ├── cache.db
# ├── config.yaml
# └── Country.mmdb

export http_proxy=http://127.0.0.1:7890 https_proxy=https://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7891
