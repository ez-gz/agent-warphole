#!/usr/bin/env bash
# Teleport — shift a coding-agent session from local to a remote VM.
#
# Usage:  teleport [go|setup]
#   go      sync session to remote and exit local (default)
#   setup   write ~/.claude/teleport.conf

set -euo pipefail

CONF="${HOME}/.claude/teleport.conf"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── commands ──────────────────────────────────────────────────────────────────

cmd_setup() {
  echo "Claude Teleport — Setup"
  echo ""
  read -rp "  Fly.io app name: " app
  [[ -n "$app" ]] || { echo "App name required." >&2; exit 1; }

  cat > "$CONF" <<EOF
TELEPORT_AGENT=claude
TELEPORT_PROVIDER=fly
FLY_APP=$app
EOF

  echo "  Config → $CONF"
  echo ""
  echo "  Before first use, ensure claude is installed on the remote:"
  echo "    fly ssh console -a $app"
  echo "    npm install -g @anthropic-ai/claude-code && claude"
}

cmd_go() {
  local session
  session=$(agent_session_id) \
    || { echo "No active session — open a project in Claude first." >&2; exit 1; }

  printf '\n  session   %s\n  remote    %s\n\n' "${session:0:16}" "$TELEPORT_PROVIDER"

  # Fail before touching anything on the remote.
  # If we can't reach the VM, the local session survives untouched.
  provider_ssh "true" &>/dev/null \
    || { echo "Remote unreachable — local session unchanged." >&2; exit 1; }

  echo "Syncing…"
  while IFS= read -r path; do
    [[ -e "$path" ]] || continue
    printf '    %s\n' "$path"
    provider_rsync "$path" "$path"
  done < <(agent_sync_paths)

  printf '\nLaunching on remote…\n'

  # -c sets the working directory so the agent starts in the right project.
  # new-session is idempotent: re-teleporting the same project reuses the window.
  provider_ssh "tmux new-session -d -s teleport-${session} -c ${PWD} 2>/dev/null || true"
  provider_ssh "tmux send-keys -t teleport-${session} '$(agent_resume_cmd "$session")' Enter"

  provider_attach "$session"
  # Clean exit signals Claude Code to end the local session.
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-go}" in
  go)
    [[ -f "$CONF" ]] || { echo "Not configured — run: teleport setup" >&2; exit 1; }
    source "$CONF"
    source "$DIR/agents/${TELEPORT_AGENT}.sh"
    source "$DIR/providers/${TELEPORT_PROVIDER}.sh"
    cmd_go
    ;;
  setup)
    cmd_setup
    ;;
  *)
    echo "Usage: teleport [go|setup]" >&2
    exit 1
    ;;
esac
