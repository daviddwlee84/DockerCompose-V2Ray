#!/bin/bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh

# setting up the Docker daemon in rootless mode
sudo apt-get update && sudo apt-get install -y uidmap
dockerd-rootless-setuptool.sh install
