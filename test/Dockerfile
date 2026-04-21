# Test "VPS": Ubuntu 22.04 with SSH + passwordless-sudo ansible user.
# Used by docker-compose.test.yml for local Ansible validation.
#
# Scope of what this validates:
#   - SSH connectivity + ansible_user setup
#   - apt install tasks in common and docker roles
#   - file/template tasks in the vpn role
#
# Not validated here:
#   - systemd service starts (no systemd in the container)
#   - docker-in-docker (the docker role installs docker but dockerd
#     can't actually run here without dind)
#   - Let's Encrypt bootstrap (requires real DNS + reachable port 80)
#
# For full end-to-end validation, deploy against a real (throwaway)
# Ubuntu VPS. This container is for the connectivity + config-rendering
# layer only.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        sudo \
        python3 \
        python3-apt \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash ansible \
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
    && sed -i 's/#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
