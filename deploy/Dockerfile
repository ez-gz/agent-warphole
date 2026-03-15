# Build context: repo root (fly deploy run from repo root, not deploy/)
# node:22-slim already has Node + npm + ca-certificates on Debian slim.
FROM node:22-slim

# tmux: persistent sessions that survive SSH disconnects
# rsync: fast delta-sync from local machines
# Non-root user: claude --dangerously-skip-permissions is blocked for root.
# rsync still lands as root; warphole chowns the synced trees before launch.
RUN apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
      tmux rsync openssh-server python3 && \
    npm install -g @anthropic-ai/claude-code && \
    npm cache clean --force && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo 'PermitRootLogin yes'      >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config && \
    echo 'Port 2222'                >> /etc/ssh/sshd_config && \
    useradd -m -s /bin/bash user

# Bake the phone UI server into the image.
# warphole go will rsync the latest version on top of this — the baked copy
# just ensures the server is available at first boot before any warphole runs.
COPY phone/ /opt/warphole/phone/

# Phone server boot wrapper: sets HOME so Path.home() resolves /home/user/.claude
RUN printf '%s\n' \
  '#!/bin/sh' \
  'HOME=/home/user exec python3 /opt/warphole/phone/controller.py --host 0.0.0.0 --port 8420' \
  > /usr/local/bin/phone-start.sh && chmod +x /usr/local/bin/phone-start.sh

WORKDIR /home/user

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
  '' \
  '# Start phone server in waiting mode — warphole go will restart it with session args' \
  'tmux new-session -d -s warphole-phone /usr/local/bin/phone-start.sh 2>/dev/null || true' \
  '' \
  'exec sleep infinity' \
  > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
