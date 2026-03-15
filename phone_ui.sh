#!/usr/bin/env bash
# Warphole phone UI — serve the current Claude Code session to your phone.
#
# Usage:
#   ./phone_ui.sh                                        # auto-detect local Claude tmux session
#   ./phone_ui.sh --session <tmux-session-name>          # explicit session
#   ./phone_ui.sh --local-session <name>                 # alias for --session
#   ./phone_ui.sh --project /path/to/project             # explicit project dir
#   ./phone_ui.sh --host 0.0.0.0 --port 8420
#
# On the remote VM (warphole): started automatically by `warphole go`.
# Access remotely via: fly proxy 8420:8420 -a <your-app>

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Translate --local-session / --local-label to controller.py args
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-session) args+=("--session" "$2"); shift 2 ;;
    --local-label)   shift 2 ;;  # reserved for future multi-session UI
    *) args+=("$1"); shift ;;
  esac
done

exec python3 "$DIR/phone/controller.py" "${args[@]+"${args[@]}"}"
