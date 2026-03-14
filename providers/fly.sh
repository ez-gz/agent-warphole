#!/usr/bin/env bash
# Fly.io provider.
#
# rsync travels through a local fly proxy tunnel rather than needing
# a public IP or open SSH port on the VM. The tunnel is lazy-started
# on first use and torn down on exit.
#
# Required config: FLY_APP (the fly.io app name)

# Ephemeral local port for the SSH tunnel. Random to avoid conflicts
# when multiple teleports run concurrently on the same machine.
_PROXY_PORT=$(( (RANDOM % 10000) + 20000 ))
_PROXY_PID=""

_SSH_OPTS="-p $_PROXY_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

_proxy_start() {
  [[ -n "$_PROXY_PID" ]] && return  # already up

  fly proxy "${_PROXY_PORT}:22" -a "$FLY_APP" &>/dev/null &
  _PROXY_PID=$!
  trap '_proxy_stop' EXIT

  # Poll until the port accepts connections (max ~5s).
  local i=0
  until nc -z localhost "$_PROXY_PORT" 2>/dev/null; do
    (( ++i > 10 )) && { echo "Fly proxy timed out." >&2; exit 1; }
    sleep 0.5
  done
}

_proxy_stop() {
  [[ -n "$_PROXY_PID" ]] && kill "$_PROXY_PID" 2>/dev/null
  _PROXY_PID=""
}

# ── provider interface ────────────────────────────────────────────────────────

provider_ssh() {
  fly ssh console -a "$FLY_APP" -C "$1"
}

provider_rsync() {
  local src="$1" dest="$2"
  _proxy_start

  # --rsync-path creates the destination directory as part of the rsync handshake,
  # eliminating a separate SSH round-trip per path.
  if [[ -d "$src" ]]; then
    rsync -az --rsync-path="mkdir -p $dest && rsync" \
      -e "ssh $_SSH_OPTS" "${src%/}/" "root@localhost:${dest%/}/"
  else
    rsync -az --rsync-path="mkdir -p $(dirname "$dest") && rsync" \
      -e "ssh $_SSH_OPTS" "$src" "root@localhost:$dest"
  fi
}

provider_attach() {
  local session="$1"
  printf '\n  Live. Attach with:\n'
  printf '  fly ssh console -a %s -C '"'"'tmux attach -t warphole-%s'"'"'\n\n' \
    "$FLY_APP" "$session"
}
