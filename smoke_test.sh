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

PASS=0; FAIL=0

ok()   { printf '  \033[32m✓\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
warn() { printf '  \033[33m~\033[0m  %s\n' "$*"; }

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
while IFS=$'\t' read -r path _dest; do
  if [[ -e "$path" ]]; then
    ok "  exists  $path"
  elif [[ "$path" == *CLAUDE.md ]]; then
    warn "optional  $path"
  else
    fail "  missing $path"
  fi
done < <(agent_sync_paths 2>/dev/null || true)

check "agent_resume_cmd returns non-empty" '[[ -n "$(agent_resume_cmd test-id)" ]]'

# ── local: phone UI ───────────────────────────────────────────────────────────
echo ""
echo "Phone UI (local)"

check "phone/controller.py exists"    "[[ -f '$DIR/phone/controller.py' ]]"
check "phone/index.html exists"       "[[ -f '$DIR/phone/index.html' ]]"
check "phone_ui.sh executable"        "[[ -x '$DIR/phone_ui.sh' ]]"
check "python3 available"             "command -v python3"
check "controller.py syntax"         "python3 -c \"import ast; ast.parse(open('$DIR/phone/controller.py').read())\""

# ── local: warphole commands ──────────────────────────────────────────────────
echo ""
echo "Warphole commands (local)"

check "warphole.sh syntax"            "bash -n '$DIR/warphole.sh'"
check "warphole skills list"          "bash '$DIR/warphole.sh' skills list"
check "warphole mcp list"             "bash '$DIR/warphole.sh' mcp list"
check "warphole log (empty ok)"       "bash '$DIR/warphole.sh' log || true"

# ── local: config ─────────────────────────────────────────────────────────────
echo ""
echo "Config"

if [[ -f "$CONF" ]]; then
  ok "$CONF exists"
  source "$CONF"
  check "WARPHOLE_AGENT set"      '[[ -n "${WARPHOLE_AGENT:-}" ]]'
  check "WARPHOLE_PROVIDER set"   '[[ -n "${WARPHOLE_PROVIDER:-}" ]]'
  check "provider adapter exists" "[[ -f '$DIR/providers/${WARPHOLE_PROVIDER:-}.sh' ]]"
  check "agent adapter exists"    "[[ -f '$DIR/agents/${WARPHOLE_AGENT:-}.sh' ]]"
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

  check "SSH reachable"        'provider_ssh "true"'
  check "tmux available"       'provider_ssh "tmux -V"'
  check "rsync available"      'provider_ssh "rsync --version"'
  check "claude available"     'provider_ssh "runuser -u user -- claude --version"'
  check "python3 available"    'provider_ssh "python3 --version"'
  check "phone server files"   'provider_ssh "[ -f /opt/warphole/phone/controller.py ]"'
  check "phone-start.sh"       'provider_ssh "[ -x /usr/local/bin/phone-start.sh ]"'

  # Check phone server is responding
  if provider_ssh "tmux has-session -t warphole-phone 2>/dev/null"; then
    ok "phone tmux session running"
    # Try to hit the health endpoint via proxy
    if command -v fly &>/dev/null && [[ -n "${FLY_APP:-}" ]]; then
      check "phone /health via fly proxy" \
        "fly proxy 18420:8420 -a '$FLY_APP' &>/dev/null & _pid=\$!; sleep 2; curl -sf http://localhost:18420/health &>/dev/null; kill \$_pid 2>/dev/null"
    fi
  else
    warn "phone tmux session not running (expected before first warphole go)"
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
