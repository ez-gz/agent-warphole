#!/usr/bin/env bash
# Smoke test — run before first warphole to verify everything is wired up.
#
# Usage:
#   ./smoke_test.sh            # local checks only (no VM needed)
#   ./smoke_test.sh --remote   # + connectivity and a live file-transfer round-trip

set -euo pipefail

CONF="${HOME}/.claude/warphole.conf"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${1:-}"
ACTIVE_AGENT=""

PASS=0; FAIL=0

ok()   { printf '  \033[32m✓\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }

check() {
  local label="$1"; shift
  if eval "$*" &>/dev/null; then ok "$label"; else fail "$label"; fi
}

process_chain_agent() {
  local pid="${PPID:-}"
  local comm=""

  while [[ -n "$pid" && "$pid" -gt 1 ]] 2>/dev/null; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')
    case "$comm" in
      *codex*) echo "codex"; return 0 ;;
      *claude*|*Claude*) echo "claude"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done

  return 1
}

agent_has_local_session() {
  local agent="$1"
  source "$DIR/agents/${agent}.sh"
  agent_session_id >/dev/null 2>&1
}

detect_agent() {
  if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    echo "codex"
    return 0
  fi

  if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_SESSION_ID:-}" ]]; then
    echo "claude"
    return 0
  fi

  if process_chain_agent >/dev/null 2>&1; then
    process_chain_agent
    return 0
  fi

  if agent_has_local_session "claude" && ! agent_has_local_session "codex"; then
    echo "claude"
    return 0
  fi

  if agent_has_local_session "codex" && ! agent_has_local_session "claude"; then
    echo "codex"
    return 0
  fi

  echo "claude"
}

ACTIVE_AGENT=$(detect_agent)

# ── local: agent ──────────────────────────────────────────────────────────────
echo ""
echo "Agent (local)"

source "$DIR/agents/${ACTIVE_AGENT}.sh"

session=$(agent_session_id 2>/dev/null || true)
if [[ -n "$session" ]]; then
  ok "agent_session_id → ${session:0:20}…"
else
  fail "agent_session_id (no active local agent session found — open the project in Claude or Codex first)"
fi

echo "  sync paths:"
while IFS=$'\t' read -r path _dest; do
  if [[ -e "$path" ]]; then
    ok "  exists  $path"
  elif [[ "$path" == *CLAUDE.md ]]; then
    # Optional — warphole skips missing paths, CLAUDE.md is created on first use
    printf '  \033[33m~\033[0m  optional  %s\n' "$path"
  else
    fail "  missing $path"
  fi
done < <(agent_sync_paths 2>/dev/null || true)

check "agent_resume_cmd returns non-empty" '[[ -n "$(agent_resume_cmd test-id)" ]]'

# ── local: config ─────────────────────────────────────────────────────────────
echo ""
echo "Config"

if [[ -f "$CONF" ]]; then
  ok "$CONF exists"
  check "WARPHOLE_PROVIDER set" '[[ -n "${WARPHOLE_PROVIDER:-}" ]]'
  check "provider adapter exists" "[[ -f '$DIR/providers/${WARPHOLE_PROVIDER:-}.sh' ]]"
  check "agent adapter exists"    "[[ -f '$DIR/agents/${ACTIVE_AGENT}.sh' ]]"
else
  fail "$CONF missing — run: warphole setup"
fi

# ── remote: provider (opt-in) ─────────────────────────────────────────────────
if [[ "$REMOTE" == "--remote" ]]; then
  echo ""
  echo "Provider (remote)"

  if [[ ! -f "$CONF" ]]; then
    fail "config missing — skipping remote tests"
  else

  source "$DIR/providers/${WARPHOLE_PROVIDER}.sh"
  source "$DIR/agents/${ACTIVE_AGENT}.sh"

  check "SSH reachable"        'provider_ssh "true"'
  check "tmux available"       'provider_ssh "tmux -V"'
  check "rsync available"      'provider_ssh "rsync --version"'
  if declare -F agent_remote_smoke_cmd >/dev/null 2>&1; then
    check "${ACTIVE_AGENT} available" "provider_ssh \"$(agent_remote_smoke_cmd)\""
  fi

  # Round-trip: write a temp file locally, sync it over, verify it landed.
  tmp_dir=$(mktemp -d)
  tmp="$tmp_dir/warphole smoke $$"
  echo "warphole-smoke-$$" > "$tmp"
  remote_path="/tmp/warphole smoke $$"
  printf -v tmp_q '%q' "$tmp"
  printf -v remote_path_q '%q' "$remote_path"

  check "rsync transfer" "provider_rsync $tmp_q $remote_path_q"
  check "file arrived on remote" "provider_ssh \"grep -q warphole-smoke-$$ $remote_path_q\""
  provider_ssh "rm -f $remote_path_q" &>/dev/null || true
  rm -rf "$tmp_dir"

  fi  # end config-present guard
fi

# ── result ────────────────────────────────────────────────────────────────────
echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
[[ $FAIL -eq 0 ]]
