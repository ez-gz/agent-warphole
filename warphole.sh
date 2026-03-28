#!/usr/bin/env bash
# agent-warphole — shift a coding-agent session from local to a remote VM.
#
# Usage:  warphole [setup | suck [--clobber] [session-id] | [message...]]
#   (no args)          sync and resume interactively
#   "execute the spec" sync, resume, and send that as the opening prompt
#   suck               pull remote state back to local and stop remote Claude
#   setup              write ~/.claude/warphole.conf

set -euo pipefail

CONF="${HOME}/.claude/warphole.conf"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCOMING_DIR="${HOME}/.claude/warphole-incoming"
STATE_DIR="${HOME}/.claude/warphole-state"
ACTIVE_AGENT=""

_remote_disable_hooks() {
  local settings_path backup_path settings_q backup_q
  settings_path="$REMOTE_HOME/.claude/settings.json"
  backup_path="$REMOTE_HOME/.claude/settings.warphole-local.json"
  printf -v settings_q '%q' "$settings_path"
  printf -v backup_q '%q' "$backup_path"

  # Keep a copy of the original local settings on the VM, then remove hooks from
  # the active remote settings so missing local-only tooling does not break the
  # resumed remote Claude session.
  provider_ssh "
    if [ -f $settings_q ]; then
      node -e '
        const fs = require(\"fs\");
        const settingsPath = process.argv[1];
        const backupPath = process.argv[2];
        const raw = fs.readFileSync(settingsPath, \"utf8\");
        fs.writeFileSync(backupPath, raw);
        const data = JSON.parse(raw);
        delete data.hooks;
        fs.writeFileSync(settingsPath, JSON.stringify(data, null, 2) + \"\\n\");
      ' $settings_q $backup_q
    fi
  " || { echo "Remote settings sanitization failed." >&2; exit 1; }
}

_remote_fix_ownership() {
  local path dest
  local -a targets=()

  while IFS=$'\t' read -r path dest; do
    [[ -e "$path" ]] || continue
    targets+=("${dest:-$path}")
  done < <(agent_sync_paths)

  [[ ${#targets[@]} -gt 0 ]] || return 0

  local command="mkdir -p $(printf '%q' "$REMOTE_HOME")"
  for dest in "${targets[@]}"; do
    command+=" && chown -R user:user $(printf '%q' "$dest")"
  done
  provider_ssh "$command"
}

_remote_paths_for_sync() {
  local path dest
  while IFS=$'\t' read -r path dest; do
    if [[ -n "${dest:-}" ]]; then
      printf '%s\t%s\n' "$path" "$dest"
    else
      printf '%s\t%s\n' "$path" "$path"
    fi
  done < <(agent_sync_paths)
}

_state_file_for_project() {
  printf '%s/%s/%s.session\n' "$STATE_DIR" "$ACTIVE_AGENT" "$1"
}

_tmux_session_name() {
  printf 'warphole-%s-%s\n' "$ACTIVE_AGENT" "$1"
}

_remote_idle_reaper_cmd() {
  local session="$1"
  local tmux_session timeout_seconds=900 poll_seconds=15
  tmux_session=$(_tmux_session_name "$session")

  cat <<EOF
session=$(printf '%q' "$tmux_session")
timeout_seconds=$timeout_seconds
poll_seconds=$poll_seconds
while tmux has-session -t "\$session" 2>/dev/null; do
  now=\$(date +%s)
  activity=\$(tmux display-message -p -t "\$session" '#{session_activity}' 2>/dev/null || printf '%s\n' "\$now")
  [[ "\$activity" =~ ^[0-9]+$ ]] || activity=\$now
  if (( now - activity >= timeout_seconds )); then
    tmux kill-session -t "\$session" 2>/dev/null || true
    exit 0
  fi
  sleep "\$poll_seconds"
done
EOF
}

_remember_remote_session() {
  local encoded_path="$1"
  local session="$2"
  local state_file
  state_file=$(_state_file_for_project "$encoded_path")
  mkdir -p "$(dirname "$state_file")"
  printf '%s\n' "$session" > "$state_file"
}

_preferred_remote_session() {
  local encoded_path="$1"
  local state_file
  state_file=$(_state_file_for_project "$encoded_path")
  [[ -f "$state_file" ]] || return 1
  tr -d '\r' < "$state_file"
}

_clear_preferred_remote_session() {
  local encoded_path="$1"
  rm -f "$(_state_file_for_project "$encoded_path")"
}

_remote_session_exists() {
  local session="$1"
  provider_ssh "tmux has-session -t $(printf '%q' "$(_tmux_session_name "$session")") 2>/dev/null"
}

_list_remote_sessions_for_project() {
  local encoded_path="$1"
  local prefix_q
  printf -v prefix_q '%q' "warphole-${ACTIVE_AGENT}-${encoded_path}__"
  provider_ssh "tmux list-sessions -F '#S' 2>/dev/null | awk -v prefix=$prefix_q -v strip=$(printf '%q' "warphole-${ACTIVE_AGENT}-") 'index(\$0, prefix) == 1 { sub(\"^\" strip, \"\", \$0); print }'" 2>/dev/null | tr -d '\r'
}

_resolve_remote_session_for_project() {
  local encoded_path="$1"
  local preferred_session="${2:-}"
  local remote_session uuid
  local -a matches=()

  if [[ -n "$preferred_session" ]] && _remote_session_exists "$preferred_session" >/dev/null 2>&1; then
    printf '%s\n' "$preferred_session"
    return 0
  fi

  while IFS= read -r remote_session; do
    [[ -n "$remote_session" ]] || continue
    matches+=("$remote_session")
  done < <(_list_remote_sessions_for_project "$encoded_path")

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    return 2
  fi

  [[ "$ACTIVE_AGENT" == "claude" ]] || return 1
  uuid=$(provider_ssh "ls -t $(printf '%q' "$REMOTE_HOME/.claude/projects/$encoded_path")/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl" 2>/dev/null | tr -d '\r')
  [[ -n "$uuid" ]] || return 1
  printf '%s__%s\n' "$encoded_path" "$uuid"
}

_project_merge_pull() {
  local remote_project="$1"
  local local_project="$2"
  local clobber="$3"
  local tmp_root incoming_root rel remote_file local_file incoming_file
  local copied=0 preserved=0 conflicts=0

  tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/warphole-pull.XXXXXX")
  incoming_root="$INCOMING_DIR${local_project}"
  provider_rsync_pull "$remote_project" "$tmp_root" || return 1

  if [[ "$clobber" == 1 ]]; then
    rsync -az --delete \
      --exclude='.git' --exclude='node_modules' \
      "${tmp_root%/}/" "${local_project%/}/"
    rm -rf "$tmp_root"
    echo "  project sync: clobbered local from remote"
    return 0
  fi

  while IFS= read -r remote_file; do
    rel="${remote_file#$tmp_root/}"
    local_file="$local_project/$rel"
    incoming_file="$incoming_root/$rel"

    if [[ ! -e "$local_file" ]]; then
      mkdir -p "$(dirname "$local_file")"
      cp "$remote_file" "$local_file"
      copied=$(( copied + 1 ))
    elif cmp -s "$remote_file" "$local_file"; then
      :
    elif [[ -d "$local_project/.git" ]] && git -C "$local_project" ls-files --error-unmatch "$rel" >/dev/null 2>&1 \
      && git -C "$local_project" diff --quiet -- "$rel"; then
      cp "$remote_file" "$local_file"
      copied=$(( copied + 1 ))
    else
      mkdir -p "$(dirname "$incoming_file")"
      cp "$remote_file" "$incoming_file"
      conflicts=$(( conflicts + 1 ))
      preserved=$(( preserved + 1 ))
    fi
  done < <(find "$tmp_root" -type f)

  rm -rf "$tmp_root"
  echo "  project sync: copied=$copied preserved_local=$preserved conflicts=$conflicts"
  [[ $conflicts -eq 0 ]] || echo "  remote conflict copies → $incoming_root"
}

# ── commands ──────────────────────────────────────────────────────────────────

_load_agent() {
  local agent="$1"
  source "$DIR/agents/${agent}.sh"
}

_load_provider() {
  source "$DIR/providers/${WARPHOLE_PROVIDER}.sh"
}

_process_chain_agent() {
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

_agent_has_local_session() {
  local agent="$1"
  _load_agent "$agent"
  agent_session_id >/dev/null 2>&1
}

_detect_agent() {
  if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    echo "codex"
    return 0
  fi

  if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_SESSION_ID:-}" ]]; then
    echo "claude"
    return 0
  fi

  if _process_chain_agent >/dev/null 2>&1; then
    _process_chain_agent
    return 0
  fi

  if _agent_has_local_session "claude" && ! _agent_has_local_session "codex"; then
    echo "claude"
    return 0
  fi

  if _agent_has_local_session "codex" && ! _agent_has_local_session "claude"; then
    echo "codex"
    return 0
  fi

  if _agent_has_local_session "claude" && _agent_has_local_session "codex"; then
    echo "Could not auto-detect agent: both Claude and Codex have local sessions for this project. Use /warphole claude or /warphole codex." >&2
    return 1
  fi

  echo "Could not auto-detect agent from environment or local session state. Use /warphole claude or /warphole codex." >&2
  return 1
}

_parse_agent_override() {
  case "${1:-}" in
    claude|codex) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

_select_agent() {
  local explicit_agent="${1:-}"

  if [[ -n "$explicit_agent" ]]; then
    ACTIVE_AGENT="$explicit_agent"
  else
    ACTIVE_AGENT=$(_detect_agent) || return 1
  fi

  _load_agent "$ACTIVE_AGENT"
}

cmd_setup() {
  echo "agent-warphole — Setup"
  echo ""
  read -rp "  Fly.io app name: " app
  [[ -n "$app" ]] || { echo "App name required." >&2; exit 1; }

  cat > "$CONF" <<EOF
WARPHOLE_PROVIDER=fly
FLY_APP=$app
REMOTE_HOME=/home/user
EOF

  echo "  Config → $CONF"
  echo ""
  echo "  Before first use, ensure claude is installed on the remote:"
  echo "    fly ssh console -a $app"
  echo "    runuser -u user -- claude"
}

cmd_go() {
  local msg="${*:-}"  # optional opening prompt to send once the remote session starts
  local session encoded_path resume_cmd
  local idle_reaper_cmd idle_reaper_cmd_q
  local pwd_q tmux_session_q resume_cmd_q
  session=$(agent_session_id) \
    || { echo "No active session — open a project in Claude first." >&2; exit 1; }
  encoded_path="${session%__*}"

  printf '\n  session   %s\n  remote    %s\n\n' "${session:0:16}" "$WARPHOLE_PROVIDER"

  # Fail before touching anything on the remote.
  # If we can't reach the VM, the local session survives untouched.
  provider_ssh "true" >/dev/null \
    || { echo "Remote unreachable — is the VM running? Try: fly status -a ${FLY_APP:-}" >&2; exit 1; }

  echo "Syncing…"
  local sync_ok=1
  while IFS=$'\t' read -r path dest; do
    dest="${dest:-$path}"  # if no dest given, path parity (same both sides)
    [[ -e "$path" ]] || continue
    printf '    %s\n' "$path"
    provider_rsync "$path" "$dest" || { echo "  rsync failed: $path" >&2; sync_ok=0; }
  done < <(agent_sync_paths)
  [[ $sync_ok -eq 1 ]] || { echo "Sync errors above — aborting to protect remote state." >&2; exit 1; }

  # rsync lands as root so the non-root claude process can read/write its own
  # session files and the synced project tree.
  _remote_fix_ownership \
    || { echo "Remote ownership fix failed." >&2; exit 1; }

  [[ "$ACTIVE_AGENT" == "claude" ]] && _remote_disable_hooks

  printf '\nLaunching on remote…\n'

  # Replace any prior remote tmux session for this local Claude session.
  # Reusing an old pane is too error-prone: it can contain stale commands or a
  # previously failed Claude process from an earlier warphole build.
  resume_cmd=$(agent_resume_cmd "$session" "$msg")
  idle_reaper_cmd=$(_remote_idle_reaper_cmd "$session")
  printf -v pwd_q '%q' "$PWD"
  printf -v tmux_session_q '%q' "$(_tmux_session_name "$session")"
  printf -v resume_cmd_q '%q' "$resume_cmd"
  printf -v idle_reaper_cmd_q '%q' "$idle_reaper_cmd"
  provider_ssh "
    tmux kill-session -t $tmux_session_q 2>/dev/null || true
    tmux new-session -d -s $tmux_session_q -c $pwd_q
    nohup bash -lc $idle_reaper_cmd_q >/dev/null 2>&1 &
    tmux send-keys -t $tmux_session_q -l -- $resume_cmd_q
    tmux send-keys -t $tmux_session_q Enter
  "

  # Brief pause then snapshot the pane so the user can see if the agent
  # started cleanly or hit an error before the terminal attach opens.
  sleep 2
  local pane_tail=""
  pane_tail=$(provider_ssh "tmux capture-pane -p -t $tmux_session_q 2>/dev/null | tail -4" 2>/dev/null | tr -d '\r') || true
  if [[ -n "$pane_tail" ]]; then
    printf '  remote pane:\n'
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && printf '    %s\n' "$_line"
    done <<< "$pane_tail"
    printf '\n'
  fi

  _remember_remote_session "$encoded_path" "$session"
  provider_attach "$session"
  # Clean exit signals Claude Code to end the local session.
}

cmd_suck() {
  local clobber=0
  local requested_session=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clobber) clobber=1 ;;
      *)
        [[ -z "$requested_session" ]] || { echo "Usage: warphole suck [--clobber] [session-id]" >&2; exit 1; }
        requested_session="$1"
        ;;
    esac
    shift
  done

  local session hint_session remote_project local_project encoded_path remote_session remote_uuid
  local path remote_path
  session=$(agent_session_id) \
    || { echo "No local session metadata found for this project." >&2; exit 1; }
  local_project="$PWD"
  remote_project="$PWD"  # Claude currently requires path parity.
  encoded_path=$(echo "$PWD" | sed 's|/|-|g')

  printf '\n  session   %s\n  action    suck\n\n' "${session:0:16}"

  provider_ssh "true" >/dev/null \
    || { echo "Remote unreachable — is the VM running? Try: fly status -a ${FLY_APP:-}" >&2; exit 1; }

  hint_session="${requested_session:-$(_preferred_remote_session "$encoded_path" 2>/dev/null || true)}"
  if remote_session=$(_resolve_remote_session_for_project "$encoded_path" "${hint_session:-$session}"); then
    :
  else
    case $? in
      2)
        echo "Multiple remote sessions found for this project. Re-run with one of:" >&2
        _list_remote_sessions_for_project "$encoded_path" | sed 's/^/  /' >&2
        exit 1
        ;;
      *)
        remote_session=""
        ;;
    esac
  fi

  echo "Pulling remote state…"
  while IFS=$'\t' read -r path remote_path; do
    if [[ "$path" == "$local_project" ]]; then
      remote_project="$remote_path"
      local_project="$path"
      continue
    fi

    if [[ "$ACTIVE_AGENT" == "claude" && "$path" == "$HOME/.claude/settings.json" ]]; then
      remote_path="$REMOTE_HOME/.claude/settings.warphole-local.json"
      provider_ssh "[ -f $(printf '%q' "$remote_path") ]" >/dev/null 2>&1 \
        || remote_path="$REMOTE_HOME/.claude/settings.json"
    fi

    printf '    %s\n' "$remote_path"
    provider_rsync_pull "$remote_path" "$path"
  done < <(_remote_paths_for_sync)

  [[ -n "$remote_project" && -n "$local_project" ]] \
    || { echo "Could not determine local/remote project paths for suck." >&2; exit 1; }

  echo "Merging project…"
  _project_merge_pull "$remote_project" "$local_project" "$clobber" \
    || { echo "Project merge failed." >&2; exit 1; }

  # Make the pulled remote session the newest local session so a later
  # `claude --continue` lands in the remote work, not the local suck-control
  # session that initiated the pull.
  if [[ -n "$remote_session" ]]; then
    remote_uuid="${remote_session##*__}"
    touch "$HOME/.claude/projects/$encoded_path/$remote_uuid.jsonl" 2>/dev/null || true
    echo "  preferred local resume session → $remote_session"
  else
    echo "  warning: could not identify remote session id; future resume may prefer the local suck session"
  fi

  printf '\nStopping remote Claude…\n'
  if [[ -n "$remote_session" ]]; then
    provider_ssh "tmux kill-session -t $(printf '%q' "$(_tmux_session_name "$remote_session")") 2>/dev/null || true"
  else
    echo "  no remote tmux session found"
  fi
  _clear_preferred_remote_session "$encoded_path"
  echo "  remote tmux session stopped"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-go}" in
  setup)
    cmd_setup
    ;;
  suck)
    [[ -f "$CONF" ]] || { echo "Not configured — run: warphole setup" >&2; exit 1; }
    source "$CONF"
    _select_agent
    _load_provider
    shift || true
    cmd_suck "$@"
    ;;
  *)
    [[ -f "$CONF" ]] || { echo "Not configured — run: warphole setup" >&2; exit 1; }
    source "$CONF"
    agent_override=""
    if agent_override=$(_parse_agent_override "${1:-}"); then
      _select_agent "$agent_override" || exit 1
      shift
      if [[ "${1:-}" == "suck" ]]; then
        _load_provider
        shift
        cmd_suck "$@"
        exit $?
      fi
    else
      _select_agent || exit 1
    fi

    _load_provider

    # Anything that isn't "setup" is treated as an optional opening prompt.
    # /warphole                       → teleport, resume interactively
    # /warphole now execute the spec  → teleport, resume, send that prompt
    [[ "${1:-}" == "go" ]] && shift || true
    cmd_go "$@"
    ;;
esac
