FROM ubuntu:24.04

# tmux: persistent sessions that survive SSH disconnects
# rsync: fast delta-sync from local machines
# Node 22 LTS: required by claude-code
RUN apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
      tmux rsync curl ca-certificates && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y -q nodejs && \
    npm install -g @anthropic-ai/claude-code && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# Nothing to run — the VM idles until teleport syncs a session and starts claude.
CMD ["sleep", "infinity"]
