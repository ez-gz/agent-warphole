#!/usr/bin/env bash
# Shared constants for agent-warphole.
#
# Sourced by warphole.sh, smoke_test.sh, phone_ui.sh.
# All magic values live here — not scattered across files.

# ── Paths ────────────────────────────────────────────────────────────────────

WARPHOLE_CONF="${HOME}/.claude/warphole.conf"
WARPHOLE_INCOMING_DIR="${HOME}/.claude/warphole-incoming"
WARPHOLE_STATE_DIR="${HOME}/.claude/warphole-state"
WARPHOLE_AUDIT_LOG="${HOME}/.claude/warphole-audit.jsonl"
WARPHOLE_REGISTRY="${HOME}/.claude/warphole-registry.json"
WARPHOLE_CLAUDE_PROJECTS="${HOME}/.claude/projects"

# ── Phone server ─────────────────────────────────────────────────────────────

WARPHOLE_PHONE_PORT="${WARPHOLE_PHONE_PORT:-8420}"
WARPHOLE_PHONE_REMOTE_DIR="/opt/warphole/phone"

# ── Session naming ───────────────────────────────────────────────────────────
# Tmux sessions: warphole-{encoded_path}__{uuid}
# encoded_path: absolute project path with / replaced by -
# The __ separator is unambiguous because encoded_path uses only [-a-z0-9]
# and uuid uses only [-a-f0-9].

WARPHOLE_SESSION_PREFIX="warphole-"
WARPHOLE_SESSION_SEP="__"

# ── Path encoding ────────────────────────────────────────────────────────────
# Claude Code encodes project paths by replacing / with - for the directory
# name under ~/.claude/projects/. This convention is replicated in:
#   agents/claude.sh    (bash: sed 's|/|-|g')
#   phone/controller.py (python: path.replace("/", "-"))
#
# Use warphole_encode_path() for any new code that needs this.

warphole_encode_path() {
  echo "$1" | sed 's|/|-|g'
}

# ── Rsync excludes ───────────────────────────────────────────────────────────

WARPHOLE_RSYNC_EXCLUDES=(--exclude='.git' --exclude='node_modules')
