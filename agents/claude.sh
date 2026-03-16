#!/usr/bin/env bash
# Claude Code agent adapter.
#
# Knows where Claude stores conversations and how to resume them.
# Swap this file to support a different agent (Codex, Gemini, etc.)
# without touching warphole.sh or any provider.

agent_session_id() {
  local encoded_path latest uuid
  local sep="${WARPHOLE_SESSION_SEP:-__}"

  # Encode project path: /Users/foo/bar → -Users-foo-bar
  if declare -f warphole_encode_path >/dev/null 2>&1; then
    encoded_path=$(warphole_encode_path "$PWD")
  else
    encoded_path=$(echo "$PWD" | sed 's|/|-|g')
  fi

  local projects_dir="${WARPHOLE_CLAUDE_PROJECTS:-$HOME/.claude/projects}"

  # Find the UUID of the active session — the most recently modified JSONL
  # in this project's directory. We capture it now, on the local machine,
  # before anything on the remote can change the mtime ordering.
  latest=$(ls -t "$projects_dir/$encoded_path"/*.jsonl 2>/dev/null | head -1)
  [[ -n "$latest" ]] || { echo "No session found in $projects_dir/$encoded_path/" >&2; return 1; }

  uuid=$(basename "$latest" .jsonl)

  # Pack both pieces into one string with the session separator.
  # encoded_path uses only [-a-z0-9], uuid uses only [-a-f0-9], so __ is unambiguous.
  echo "${encoded_path}${sep}${uuid}"
}

agent_sync_paths() {
  local session encoded_path
  local sep="${WARPHOLE_SESSION_SEP:-__}"
  local projects_dir="${WARPHOLE_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
  local registry="${WARPHOLE_REGISTRY:-$HOME/.claude/warphole-registry.json}"

  session=$(agent_session_id)
  encoded_path="${session%${sep}*}"

  # Output: src<tab>dest  (tab-separated)
  # .claude lives under $HOME locally but $REMOTE_HOME on the VM — remap it.
  # The project dir uses path parity (same absolute path both sides) so Claude
  # can find it by encoding $PWD, which is identical on both machines.
  local remote_home="${REMOTE_HOME:-$HOME}"
  printf '%s\t%s\n' \
    "$projects_dir/$encoded_path"     "$remote_home/.claude/projects/$encoded_path" \
    "$HOME/.claude/settings.json"     "$remote_home/.claude/settings.json" \
    "$HOME/.claude/CLAUDE.md"         "$remote_home/.claude/CLAUDE.md"

  # Sync registry if it exists (skills + MCP metadata)
  if [[ -f "$registry" ]]; then
    printf '%s\t%s\n' "$registry" "$remote_home/.claude/warphole-registry.json"
  fi

  # Project dir: no tab → warphole.sh falls back to same path both sides
  printf '%s\n' "$PWD"
}

agent_resume_cmd() {
  local session="$1"
  local msg="${2:-}"
  local sep="${WARPHOLE_SESSION_SEP:-__}"
  local encoded_path="${session%${sep}*}"
  local uuid="${session##*${sep}}"
  local remote_home="${REMOTE_HOME:-/home/user}"
  local session_file inner claude_cmd project_path

  # Touch our specific JSONL to win the mtime race against any sessions
  # that auth or other claude invocations may have created on the remote.
  printf -v session_file '%q' "$remote_home/.claude/projects/${encoded_path}/${uuid}.jsonl"
  printf -v project_path '%q' "$PWD"
  claude_cmd="claude --dangerously-skip-permissions --continue"

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
