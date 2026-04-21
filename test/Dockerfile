# Test "VPS": Ubuntu 24.04 + SSH + passwordless-sudo ansible user.
# Used by docker-compose.test.yml for local Ansible validation.
#
# Scope of what this validates:
#   - SSH connectivity + ansible_user setup (just test-ping)
#   - apt tasks from the common / docker roles (apt install, apt update)
#   - File / template rendering in the vpn role
#
# NOT validated here:
#   - systemd service starts — no systemd in the container
#   - docker-in-docker — no dockerd, so `vpn`/`letsencrypt` roles that run
#     `docker compose up` won't work here
#   - Let's Encrypt bootstrap — requires real DNS + port 80 from the internet
#
# Network detail: the image rewrites the default Ubuntu mirrors
# (ports.ubuntu.com / archive.ubuntu.com / security.ubuntu.com) to
# mirrors.tuna.tsinghua.edu.cn before any apt operation. This keeps the
# test harness bootstrap-self-contained — it does NOT depend on any proxy
# or VPN being up, which matters because this IS the VPN project. If the
# Ubuntu mirrors were reachable from a Chinese network the harness
# wouldn't exist in the first place.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Swap Ubuntu's default mirrors for Tsinghua's before any apt operation.
# 24.04 uses the deb822 format at /etc/apt/sources.list.d/ubuntu.sources;
# older layouts keep /etc/apt/sources.list. Handle both.
RUN set -eu; \
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i -E \
            -e 's|https?://ports\.ubuntu\.com/ubuntu-ports/?|http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/|g' \
            -e 's|https?://(archive\|security)\.ubuntu\.com/ubuntu/?|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
            /etc/apt/sources.list.d/ubuntu.sources; \
    elif [ -f /etc/apt/sources.list ]; then \
        sed -i -E \
            -e 's|https?://ports\.ubuntu\.com/ubuntu-ports/?|http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/|g' \
            -e 's|https?://(archive\|security)\.ubuntu\.com/ubuntu/?|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
            /etc/apt/sources.list; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        sudo \
        python3 \
        python3-apt \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash ansible \
    && usermod -p '*' ansible \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
    && chmod 440 /etc/sudoers.d/ansible \
    && mkdir -p /home/ansible/.ssh \
    && chmod 700 /home/ansible/.ssh \
    && chown ansible:ansible /home/ansible/.ssh

COPY ssh/id_ed25519.pub /home/ansible/.ssh/authorized_keys
RUN chmod 600 /home/ansible/.ssh/authorized_keys \
    && chown ansible:ansible /home/ansible/.ssh/authorized_keys

RUN mkdir -p /run/sshd \
    && ssh-keygen -A \
    && sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin no|' /etc/ssh/sshd_config \
    && sed -i 's|^#\?PasswordAuthentication.*|PasswordAuthentication no|' /etc/ssh/sshd_config \
    && sed -i 's|^#\?PubkeyAuthentication.*|PubkeyAuthentication yes|' /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
