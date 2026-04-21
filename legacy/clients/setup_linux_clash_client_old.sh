#!/bin/bash
# https://welling.fun/archives/zai-fu-wu-qi-shang-pei-zhi-clashdai-li

target_dir="."

wget https://github.com/Dreamacro/clash/releases/download/v1.14.0/clash-linux-amd64-v1.14.0.gz
gunzip clash-linux-amd64-v1.14.0.gz
mv clash-linux-amd64-v1.14.0 clash
chmod u+x $target_dir/clash

wget https://github.com/Dreamacro/maxmind-geoip/releases/download/20230312/Country.mmdb
mv Country.mmdb $target_dir/Country.mmdb

# Seems config doesn't fit..
cp ../example/clash_for_windows.yml config.yaml

export http_proxy=http://127.0.0.1:7890 https_proxy=https://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7891

# To cancel
# unset http_proxy https_proxy all_proxy

