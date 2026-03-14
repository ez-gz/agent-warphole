#!/usr/bin/env bash
# OpenAI Codex CLI agent adapter.
#
# Codex stores sessions under ~/.codex/sessions/, each as a JSON file
# named by a UUID. The active session for a project is tracked in
# ~/.codex/sessions/.current — written by codex on every invocation.
#
# Verify these paths against your installed codex version:
#   codex --version   and check ~/.codex/ after a session.

agent_session_id() {
  # Unlike Claude, Codex session IDs are UUIDs unrelated to the project path.
  # Read the pointer file codex maintains for the most recent session.
  local current="$HOME/.codex/sessions/.current"
  [[ -f "$current" ]] || { echo "No codex session found at $current" >&2; return 1; }
  cat "$current"
}

agent_sync_paths() {
  local session_id session_file
  session_id=$(agent_session_id)
  session_file="$HOME/.codex/sessions/${session_id}.json"

  # Codex needs its session file, global config, and the project source.
  # Unlike Claude there's no per-project path encoding — session files are flat.
  printf '%s\n' \
    "$session_file" \
    "$HOME/.codex/config.json" \
    "$PWD"
}

agent_resume_cmd() {
  local session_id="$1"
  # --session resumes by UUID; codex reads the session file we just synced.
  echo "codex --session $session_id"
}
