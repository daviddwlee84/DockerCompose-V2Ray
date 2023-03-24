# Deploy V2Ray with Docker Compose

Update from the original repo:

1. Add additional notes for trouble shooting
2. Update guidelines such as the latest usage of docker compose

## Steps

### 1. Setup VPS

> Using Azure as an example

1. Create a Virtual Machine
   1. Any kind of Size (schema) will work, but you can use exactly the same as mine
      1. Size: Standard B2s (2 vcpus, 4 GiB memory)
      2. Operating system: Linux (ubuntu 20.04)
      3. Location: Japan East
      4. Disk: Standard SSD
   2. Make sure you disable the auto-shutdown scheduling
2. Once the VM creation complete
   1. Open necessary ports, in this case you need to open 80, 443
   2. Create a DNS name: such as `your-dns-name`
      1. You can use a dynamic IP address
      2. You will be able to connect to your machine by using `your-dns-name.japaneast.cloudapp.azure.com` depending on the machine's location

### 2. Setup Environment

> `ssh` into your machine

1. Install `docker`
   1. Download auto setup script and run: `curl -fsSL https://get.docker.com -o get-docker.sh` then `sh get-docker.sh`
   2. Add user to docker user group (so you don't need `sudo` to use `docker`): `gpasswd -a $USER docker`
   3. Make docker auto start on boot: `sudo systemctl start docker` then `sudo systemctl enable docker`
2. Install `docker compose` ([Install Docker Compose | Docker Documentation](https://docs.docker.com/compose/install/))
   1. `DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}`
   2. `mkdir -p $DOCKER_CONFIG/cli-plugins`
   3. `curl -SL https://github.com/docker/compose/releases/download/v2.4.1/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose`
   4. `chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose`

### 3. Clone Code and Config

1. Download some CLI tools
   1. `sudo apt update`
   2. `sudo apt install git vim tmux`
2. `git clone https://github.com/daviddwlee84/DockerCompose-V2Ray.git` and `cd DockerCompose-V2Ray`
3. Modify settings
   1. `init-letsencrypt.sh`
      1. Modify `domains` and `email` to be your own
      2. If you are using Azure, the `domains` is `your-dns-name.japaneast.cloudapp.azure.com`
      3. Note that `domains` SHOULD BE AN ARRAY, that is you should keep the parenthesis there.
   2. `docker-compose.yml`
      1. No need to modify
   3. `data/v2ray/config.json`
      1. Change id to use your own `"id": "bae399d4-13a4-46a3-b144-4af2c0004c2e"` (or you can leave it as what it is)
      2. You can generate new UUID using this online tool: [Online UUID Generator Tool](https://www.uuidgenerator.net/)
   4. `data/nginx/conf.d/v2ray.conf`
      1. Modify all `your_domain`
      2. You can use vim `:%s/your_domain/your-dns-name.japaneast.cloudapp.azure.com/g`<br>
      _**Note that this modification is necessary**_ though it will be backed up, overridden by `init-letsencrypt.sh` and restored during running `./init-letsencrypt.sh`. It will be used by nginx docker afterwards.
4. Setup Nginx and HTTPS encryption stuff
    1. `chmod +x ./init-letsencrypt.sh`
    2. `./init-letsencrypt.sh`
5. Start server
   1. `tmux`
   2. `docker compose up`

> You should be able to close your terminal now

### 4. Config Your Client

1. Address: `your-dns-name.japaneast.cloudapp.azure.com`
2. Port: `443`
3. UUID: `bae399d4-13a4-46a3-b144-4af2c0004c2e`
4. Alert ID: 64
5. Method: auto
6. TLS
   1. enable
   2. allow insecure
7. Transport: `websocket`
   1. Path: `/v2ray`

## Trouble Shooting

You can see `logs/` folder

Use `sudo tail -f ./path/to/log.log` to see the error message then debug

1. If you forgot to open `80,443` ports, you will fail at certbot step. Remove `data/certbot` folder and try again.
2. If your Nginx server successfully running, you can connect to `https://your-dns-name.japaneast.cloudapp.azure.com` using a browser and see "Congratulation!" which basically is this HTML ([`data/nginx/html/v2ray/index.html`](data/nginx/html/v2ray/index.html))
3. You can connect to `https://your-dns-name.japaneast.cloudapp.azure.com/v2ray`
   1. If you get a 502 error, that means your V2Ray server is not running correctly.
   2. If you get the text "bad request", that means it successfully running.
