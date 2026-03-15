# node:22-slim already has Node + npm + ca-certificates on Debian slim.
# Saves ~300MB vs ubuntu:24.04 + NodeSource setup + nodejs apt install.
# Use node:22-alpine for an even smaller image (~half the size) if claude-code
# has no glibc dependencies — untested.
FROM node:22-slim

# tmux: persistent sessions that survive SSH disconnects
# rsync: fast delta-sync from local machines
# Non-root user: agent CLIs should run as "user", not root.
# rsync still lands as root; warphole chowns the synced trees before launch.
RUN apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
      ca-certificates tmux rsync openssh-server python3 && \
    npm install -g @anthropic-ai/claude-code @openai/codex && \
    npm cache clean --force && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo 'PermitRootLogin yes'    >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config && \
    echo 'Port 2222'              >> /etc/ssh/sshd_config && \
    useradd -m -s /bin/bash user

WORKDIR /home/user

# Inline the entrypoint without Docker heredocs so Fly/Depot parsing stays simple.
RUN printf '%s\n' \
  '#!/bin/sh' \
  'set -e' \
  '' \
  'ssh-keygen -A -q 2>/dev/null || true' \
  '' \
  'mkdir -p /run/sshd /root/.ssh' \
  'chmod 700 /root/.ssh' \
  '' \
  'if [ -z "${SSH_PUBKEY:-}" ]; then' \
  '  echo "ERROR: SSH_PUBKEY secret is not set." >&2' \
  'else' \
  '  grep -qxF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || printf "%s\n" "$SSH_PUBKEY" >> /root/.ssh/authorized_keys' \
  'fi' \
  'chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true' \
  '' \
  'mkdir -p /home/user/.ssh' \
  'cp /root/.ssh/authorized_keys /home/user/.ssh/authorized_keys' \
  'chmod 700 /home/user/.ssh' \
  'chmod 600 /home/user/.ssh/authorized_keys' \
  'chown -R user:user /home/user/.ssh' \
  '' \
  '/usr/sbin/sshd' \
  'exec sleep infinity' \
  > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
