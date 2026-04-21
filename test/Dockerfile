# Test "VPS": Alpine + SSH + passwordless-sudo ansible user.
# Used by docker-compose.test.yml for local Ansible validation.
#
# Alpine chosen over Ubuntu because ports.ubuntu.com (arm64) is
# flaky from the user's network; alpine's CDN is reliable.
#
# Scope of what this validates:
#   - SSH connectivity + ansible_user setup (just test-ping)
#   - Ansible can open an SSH session and run arbitrary commands
#
# Not validated here:
#   - systemd service starts (no systemd in the container)
#   - docker-in-docker (no dockerd)
#   - Ubuntu-specific apt tasks in the common/docker roles
#     (Alpine uses apk; those tasks will fail)
#   - Let's Encrypt bootstrap (requires real DNS + port 80)
#
# For full end-to-end validation, deploy against a real Ubuntu VPS.

FROM alpine:3.20

RUN apk add --no-cache \
        openssh-server \
        openssh-client \
        sudo \
        python3 \
        bash \
        ca-certificates \
        curl \
        shadow

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

RUN ssh-keygen -A \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
