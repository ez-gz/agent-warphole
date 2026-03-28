#!/usr/bin/env bash
# Fly.io provider.
#
# rsync travels through a local fly proxy tunnel rather than needing
# a public IP or open SSH port on the VM. The tunnel is lazy-started
# on first use and torn down on exit.
#
# Required config: FLY_APP (the fly.io app name)

# macOS ships without GNU timeout; gtimeout is coreutils via homebrew.
_timeout() { (command -v gtimeout &>/dev/null && gtimeout "$@") || (command -v timeout &>/dev/null && timeout "$@") || { shift; "$@"; }; }

# Ephemeral local port for the SSH tunnel. Random to avoid conflicts
# when multiple teleports run concurrently on the same machine.
_PROXY_PORT=$(( (RANDOM % 10000) + 20000 ))
_PROXY_PID=""

_SSH_OPTS="-p $_PROXY_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

_rsync_remote_spec() {
  printf 'root@localhost:%q' "$1"
}

_rsync_remote_mkdir_cmd() {
  printf 'mkdir -p %q && rsync' "$1"
}

_proxy_start() {
  [[ -n "$_PROXY_PID" ]] && return  # already up

  fly proxy "${_PROXY_PORT}:2222" -a "$FLY_APP" &>/dev/null &
  _PROXY_PID=$!
  trap '_proxy_stop' EXIT

  # Poll until the port accepts connections (max ~6s before assuming stopped).
  local i=0
  until nc -z localhost "$_PROXY_PORT" 2>/dev/null; do
    (( ++i > 12 )) && break
    sleep 0.5
  done

  if ! nc -z localhost "$_PROXY_PORT" 2>/dev/null; then
    # Proxy didn't come up — machine is likely stopped. Look up machine IDs
    # and start each one (fly machine start requires an explicit ID).
    printf 'Starting remote VM…\n' >&2
    kill "$_PROXY_PID" 2>/dev/null; _PROXY_PID=""
    fly machine list -a "$FLY_APP" --json 2>/dev/null \
      | grep -oE '"id":"[0-9a-f]+"' | cut -d'"' -f4 \
      | while IFS= read -r _mid; do fly machine start "$_mid" -a "$FLY_APP" 2>/dev/null || true; done
    sleep 3  # let sshd come up before retrying the proxy
    fly proxy "${_PROXY_PORT}:2222" -a "$FLY_APP" &>/dev/null &
    _PROXY_PID=$!
    local j=0
    until nc -z localhost "$_PROXY_PORT" 2>/dev/null; do
      (( ++j > 30 )) && { printf 'Remote unreachable after start. Try: fly status -a %s\n' "${FLY_APP:-}" >&2; exit 1; }
      sleep 0.5
    done
  fi
}

_proxy_stop() {
  [[ -n "$_PROXY_PID" ]] && kill "$_PROXY_PID" 2>/dev/null
  _PROXY_PID=""
}

_host_terminal_app() {
  case "${TERM_PROGRAM:-}" in
    ghostty) echo "Ghostty"; return 0 ;;
    Apple_Terminal) echo "Terminal"; return 0 ;;
    iTerm.app) echo "iTerm"; return 0 ;;
  esac

  local pid="${PPID:-}"
  local comm=""
  while [[ -n "$pid" && "$pid" -gt 1 ]] 2>/dev/null; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')
    case "$comm" in
      */ghostty|ghostty) echo "Ghostty"; return 0 ;;
      *iTerm*|*/iTerm) echo "iTerm"; return 0 ;;
      */Terminal|Terminal) echo "Terminal"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done

  return 1
}

# ── provider interface ────────────────────────────────────────────────────────

provider_ssh() {
  # Route through the proxy tunnel (same path as rsync) — avoids a separate
  # WireGuard handshake for every SSH command.
  _proxy_start
  _timeout 30 ssh $_SSH_OPTS root@localhost "bash -lc $(printf '%q' "$1")"
}

provider_rsync() {
  local src="$1" dest="$2"
  local remote_spec mkdir_cmd
  _proxy_start

  # --rsync-path creates the destination directory as part of the rsync handshake,
  # eliminating a separate SSH round-trip per path.
  if [[ -d "$src" ]]; then
    remote_spec=$(_rsync_remote_spec "${dest%/}/")
    mkdir_cmd=$(_rsync_remote_mkdir_cmd "$dest")
    rsync -az --rsync-path="$mkdir_cmd" \
      --exclude='.git' --exclude='node_modules' \
      -e "ssh $_SSH_OPTS" "${src%/}/" "$remote_spec"
  else
    remote_spec=$(_rsync_remote_spec "$dest")
    mkdir_cmd=$(_rsync_remote_mkdir_cmd "$(dirname "$dest")")
    rsync -az --rsync-path="$mkdir_cmd" \
      -e "ssh $_SSH_OPTS" "$src" "$remote_spec"
  fi
}

provider_rsync_pull() {
  local src="$1" dest="$2"
  local remote_spec
  _proxy_start

  if provider_ssh "[ -d $(printf '%q' "$src") ]" >/dev/null 2>&1; then
    mkdir -p "$dest"
    remote_spec=$(_rsync_remote_spec "${src%/}/")
    rsync -az \
      --exclude='.git' --exclude='node_modules' \
      -e "ssh $_SSH_OPTS" "$remote_spec" "${dest%/}/"
  else
    mkdir -p "$(dirname "$dest")"
    remote_spec=$(_rsync_remote_spec "$src")
    rsync -az \
      -e "ssh $_SSH_OPTS" "$remote_spec" "$dest"
  fi
}

provider_attach() {
  local session="$1"
  local tmux_session="warphole-${ACTIVE_AGENT}-${session}"
  local attach_script="$HOME/.claude/warphole-attach-${ACTIVE_AGENT}.sh"
  local host_app
  local ghostty_width="${WARPHOLE_GHOSTTY_WINDOW_WIDTH:-140}"
  local ghostty_height="${WARPHOLE_GHOSTTY_WINDOW_HEIGHT:-45}"

  printf '#!/bin/bash\nTERM=xterm-256color fly ssh console -a %s --pty -C '"'"'tmux attach -t %s'"'"'\n' \
    "$FLY_APP" "$tmux_session" > "$attach_script"
  chmod +x "$attach_script"

  host_app=$(_host_terminal_app || true)

  # Prefer the terminal that is actually hosting this Claude session.
  case "$host_app" in
    Ghostty)
      # Ghostty on macOS doesn't expose a stable "open tab in this exact window"
      # API, but it does accept config keys as CLI args for the new window.
      open -na "Ghostty" --args \
        "--window-width=$ghostty_width" \
        "--window-height=$ghostty_height" \
        -e "$attach_script" >/dev/null 2>&1 \
        || { printf '\n  Could not open Ghostty. Run manually:\n  %s\n\n' "$attach_script"; return 0; }
      ;;
    iTerm)
      osascript \
        -e 'tell application "iTerm"' \
        -e 'activate' \
        -e 'if (count windows) = 0 then' \
        -e '  create window with default profile command "'"$attach_script"'"' \
        -e 'else' \
        -e '  tell current window to create tab with default profile command "'"$attach_script"'"' \
        -e 'end if' \
        -e 'end tell' 2>/dev/null \
        || { printf '\n  Could not open terminal tab. Run manually:\n  %s\n\n' "$attach_script"; return 0; }
      ;;
    Terminal|"")
      osascript \
        -e 'tell application "Terminal"' \
        -e 'activate' \
        -e 'if (count windows) = 0 then' \
        -e '  do script "'"$attach_script"'"' \
        -e 'else' \
        -e '  do script "'"$attach_script"'" in front window' \
        -e 'end if' \
        -e 'end tell' 2>/dev/null \
        || { printf '\n  Could not open terminal tab. Run manually:\n  %s\n\n' "$attach_script"; return 0; }
      ;;
  esac

  printf '\n  Session live — terminal attach opened.\n\n'
}
