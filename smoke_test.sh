#!/usr/bin/env bash
# Smoke test — run before first teleport to verify everything is wired up.
#
# Usage:
#   ./smoke_test.sh            # local checks only (no VM needed)
#   ./smoke_test.sh --remote   # + connectivity and a live file-transfer round-trip

set -euo pipefail

CONF="${HOME}/.claude/teleport.conf"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${1:-}"

PASS=0; FAIL=0

ok()   { printf '  \033[32m✓\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }

check() {
  local label="$1"; shift
  if eval "$*" &>/dev/null; then ok "$label"; else fail "$label"; fi
}

# ── local: agent ──────────────────────────────────────────────────────────────
echo ""
echo "Agent (local)"

source "$DIR/agents/claude.sh"

session=$(agent_session_id 2>/dev/null || true)
if [[ -n "$session" ]]; then
  ok "agent_session_id → ${session:0:20}…"
else
  fail "agent_session_id (no active Claude session found — open a project first)"
fi

echo "  sync paths:"
while IFS= read -r path; do
  if [[ -e "$path" ]]; then
    ok "  exists  $path"
  elif [[ "$path" == *CLAUDE.md ]]; then
    # Optional — teleport skips missing paths, CLAUDE.md is created on first use
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
  source "$CONF"
  check "TELEPORT_AGENT set"    '[[ -n "${TELEPORT_AGENT:-}" ]]'
  check "TELEPORT_PROVIDER set" '[[ -n "${TELEPORT_PROVIDER:-}" ]]'
  check "provider adapter exists" "[[ -f '$DIR/providers/${TELEPORT_PROVIDER:-}.sh' ]]"
  check "agent adapter exists"    "[[ -f '$DIR/agents/${TELEPORT_AGENT:-}.sh' ]]"
else
  fail "$CONF missing — run: teleport setup"
fi

# ── remote: provider (opt-in) ─────────────────────────────────────────────────
if [[ "$REMOTE" == "--remote" ]]; then
  echo ""
  echo "Provider (remote)"

  [[ -f "$CONF" ]] || { fail "config missing — skipping remote tests"; }

  source "$DIR/providers/${TELEPORT_PROVIDER}.sh"

  check "SSH reachable"        'provider_ssh "true"'
  check "tmux available"       'provider_ssh "tmux -V"'
  check "rsync available"      'provider_ssh "rsync --version"'
  check "claude available"     'provider_ssh "claude --version"'

  # Round-trip: write a temp file locally, sync it over, verify it landed.
  tmp=$(mktemp)
  echo "teleport-smoke-$$" > "$tmp"
  remote_path="/tmp/teleport-smoke-$$"

  check "rsync transfer" "provider_rsync $tmp $remote_path"
  check "file arrived on remote" "provider_ssh 'grep -q teleport-smoke-$$ $remote_path'"
  provider_ssh "rm -f $remote_path" &>/dev/null || true
  rm -f "$tmp"
fi

# ── result ────────────────────────────────────────────────────────────────────
echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
[[ $FAIL -eq 0 ]]
