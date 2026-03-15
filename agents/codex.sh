#!/usr/bin/env bash
# OpenAI Codex CLI agent adapter.
#
# Current Codex CLI stores session transcripts as JSONL files under
# ~/.codex/sessions/YYYY/MM/DD/. The active project session can be recovered
# by finding the most recent transcript whose session metadata records $PWD.

_codex_project_key() {
  echo "$PWD" | sed 's|/|-|g'
}

_codex_latest_session_file() {
  local latest=""
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if grep -qF "\"cwd\":\"$PWD\"" "$candidate"; then
      latest="$candidate"
      break
    fi
  done < <(find "$HOME/.codex/sessions" -type f -name '*.jsonl' -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | cut -d' ' -f2-)

  [[ -n "$latest" ]] || { echo "No codex session found for $PWD under ~/.codex/sessions/" >&2; return 1; }
  printf '%s\n' "$latest"
}

_codex_uuid_from_session() {
  local session="$1"
  printf '%s\n' "${session##*__}"
}

_codex_session_file_for_uuid() {
  local uuid="$1"
  local session_file
  session_file=$(find "$HOME/.codex/sessions" -type f -name "*${uuid}.jsonl" -print -quit)
  [[ -n "$session_file" ]] || { echo "No codex session file found for $uuid" >&2; return 1; }
  printf '%s\n' "$session_file"
}

agent_session_id() {
  local latest uuid
  latest=$(_codex_latest_session_file) || return 1
  uuid=$(basename "$latest" .jsonl | grep -oE '[0-9a-f-]{36}$')
  [[ -n "$uuid" ]] || { echo "Could not parse codex session id from $latest" >&2; return 1; }
  printf '%s__%s\n' "$(_codex_project_key)" "$uuid"
}

agent_sync_paths() {
  local session_id session_uuid session_file remote_home
  session_id=$(agent_session_id)
  session_uuid=$(_codex_uuid_from_session "$session_id")
  session_file=$(_codex_session_file_for_uuid "$session_uuid")
  remote_home="${REMOTE_HOME:-$HOME}"

  # Sync the active session transcript, auth/config, and a few small state dirs
  # that influence Codex behavior. The project itself still uses path parity.
  printf '%s\t%s\n' \
    "$session_file"                 "$remote_home/.codex/sessions/${session_file#$HOME/.codex/sessions/}" \
    "$HOME/.codex/auth.json"        "$remote_home/.codex/auth.json" \
    "$HOME/.codex/config.toml"      "$remote_home/.codex/config.toml" \
    "$HOME/.codex/memories"         "$remote_home/.codex/memories" \
    "$HOME/.codex/rules"            "$remote_home/.codex/rules" \
    "$HOME/.codex/skills"           "$remote_home/.codex/skills" \
    "$HOME/.codex/shell_snapshots"  "$remote_home/.codex/shell_snapshots"
  printf '%s\n' "$PWD"
}

agent_resume_cmd() {
  local session="$1"
  local msg="${2:-}"
  local session_uuid inner project_path codex_cmd

  session_uuid=$(_codex_uuid_from_session "$session")
  printf -v project_path '%q' "$PWD"
  printf -v codex_cmd 'codex resume --dangerously-bypass-approvals-and-sandbox -C %q %q' "$PWD" "$session_uuid"

  if [[ -n "$msg" ]]; then
    printf -v codex_cmd '%s %q' "$codex_cmd" "$msg"
  fi

  inner="cd $project_path && $codex_cmd"
  printf 'runuser -u user -- bash -lc %q\n' "$inner"
}

agent_remote_smoke_cmd() {
  echo "runuser -u user -- codex --version"
}
