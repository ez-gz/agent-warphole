#!/usr/bin/env bash
# Claude Code agent adapter.
#
# Knows where Claude stores conversations and how to resume them.
# Swap this file to support a different agent (Codex, Gemini, etc.)
# without touching warphole.sh or any provider.

agent_session_id() {
  local encoded_path latest uuid
  encoded_path=$(echo "$PWD" | sed 's|/|-|g')

  # Find the UUID of the active session — the most recently modified JSONL
  # in this project's directory. We capture it now, on the local machine,
  # before anything on the remote can change the mtime ordering.
  latest=$(ls -t "$HOME/.claude/projects/$encoded_path"/*.jsonl 2>/dev/null | head -1)
  [[ -n "$latest" ]] || { echo "No session found in ~/.claude/projects/$encoded_path/" >&2; return 1; }

  uuid=$(basename "$latest" .jsonl)

  # Pack both pieces into one string with __ as separator (safe for tmux names).
  # encoded_path uses only [-a-z0-9], uuid uses [-a-f0-9], so __ is unambiguous.
  echo "${encoded_path}__${uuid}"
}

agent_sync_paths() {
  local session encoded_path
  session=$(agent_session_id)
  encoded_path="${session%__*}"

  # Output: src<tab>dest  (tab-separated)
  # .claude lives under $HOME locally but $REMOTE_HOME on the VM — remap it.
  # The project dir uses path parity (same absolute path both sides) so Claude
  # can find it by encoding $PWD, which is identical on both machines.
  local remote_home="${REMOTE_HOME:-$HOME}"
  printf '%s\t%s\n' \
    "$HOME/.claude/projects/$encoded_path" "$remote_home/.claude/projects/$encoded_path" \
    "$HOME/.claude/settings.json"          "$remote_home/.claude/settings.json" \
    "$HOME/.claude/CLAUDE.md"              "$remote_home/.claude/CLAUDE.md"
  # Project dir: no tab → warphole.sh falls back to same path both sides
  printf '%s\n' "$PWD"
}

agent_resume_cmd() {
  local session="$1"
  local msg="${2:-}"
  local encoded_path="${session%__*}"
  local uuid="${session##*__}"
  local remote_home="${REMOTE_HOME:-/home/user}"
  local session_file inner claude_cmd project_path

  # Touch our specific JSONL to win the mtime race against any sessions
  # that auth or other claude invocations may have created on the remote.
  printf -v session_file '%q' "$remote_home/.claude/projects/${encoded_path}/${uuid}.jsonl"
  printf -v project_path '%q' "$PWD"
  claude_cmd="claude --dangerously-skip-permissions --continue $uuid"

  if [[ -n "$msg" ]]; then
    printf -v claude_cmd '%s %q' "$claude_cmd" "$msg"
  fi

  # runuser -l resets state in ways we don't want here; explicitly cd back to
  # the synced project path before resuming so Claude looks up the right session.
  inner="cd $project_path && touch $session_file && $claude_cmd"

  # Switch to the non-root user for claude itself, but keep the command bound
  # to the synced project path.
  printf 'runuser -u user -- bash -lc %q\n' "$inner"
}

agent_remote_smoke_cmd() {
  echo "runuser -u user -- claude --version"
}
