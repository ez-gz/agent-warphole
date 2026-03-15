#!/usr/bin/env bash
# agent-warphole — shift a coding-agent session from local to a remote VM.
#
# Usage:  warphole [setup | go | suck | list | status | log | skills | mcp | ...]
#   (no args / go)         sync and resume interactively
#   "execute the spec"     sync, resume, and send that as the opening prompt
#   suck                   pull remote state back to local and stop remote Claude
#   list                   list remote sessions for this project
#   status                 show remote session status for this project
#   log                    view warphole audit log
#   skills <sub>           install/list/remove slash-command skills
#   mcp    <sub>           add/list/remove MCP servers
#   setup                  write ~/.claude/warphole.conf

set -euo pipefail

CONF="${HOME}/.claude/warphole.conf"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCOMING_DIR="${HOME}/.claude/warphole-incoming"
STATE_DIR="${HOME}/.claude/warphole-state"
AUDIT_LOG="${HOME}/.claude/warphole-audit.jsonl"
REGISTRY="${HOME}/.claude/warphole-registry.json"

# ── audit log ─────────────────────────────────────────────────────────────────

_audit_log() {
  local op="$1"; shift
  python3 -c "
import json, sys, time
entry = {'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'op': sys.argv[1], 'project': sys.argv[2]}
args = sys.argv[3:]
for i in range(0, len(args)-1, 2):
    entry[args[i]] = args[i+1]
print(json.dumps(entry))
" "$op" "$PWD" "$@" >> "$AUDIT_LOG" 2>/dev/null || true
}

# ── registry helpers ───────────────────────────────────────────────────────────

_registry_update() {
  python3 -c "
import json, sys, os
path = os.path.expanduser('~/.claude/warphole-registry.json')
data = {}
if os.path.exists(path):
    try: data = json.loads(open(path).read())
    except: pass
section, name, entry = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
if section not in data: data[section] = {}
data[section][name] = entry
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1" "$2" "$3"
}

_registry_remove() {
  python3 -c "
import json, sys, os
path = os.path.expanduser('~/.claude/warphole-registry.json')
if not os.path.exists(path): sys.exit(0)
data = json.loads(open(path).read())
data.get(sys.argv[1], {}).pop(sys.argv[2], None)
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1" "$2"
}

# ── settings.json MCP helpers ─────────────────────────────────────────────────

_settings_mcp_add() {
  python3 -c "
import json, sys, os
path = os.path.expanduser('~/.claude/settings.json')
data = {}
if os.path.exists(path):
    try: data = json.loads(open(path).read())
    except: pass
if 'mcpServers' not in data: data['mcpServers'] = {}
parts = sys.argv[2].split()
data['mcpServers'][sys.argv[1]] = {'command': parts[0], 'args': parts[1:]} if parts else {'command': ''}
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1" "$2"
}

_settings_mcp_remove() {
  python3 -c "
import json, sys, os
path = os.path.expanduser('~/.claude/settings.json')
if not os.path.exists(path): sys.exit(0)
data = json.loads(open(path).read())
data.get('mcpServers', {}).pop(sys.argv[1], None)
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1"
}

# ── remote helpers ────────────────────────────────────────────────────────────

_remote_disable_hooks() {
  local settings_path backup_path settings_q backup_q
  settings_path="$REMOTE_HOME/.claude/settings.json"
  backup_path="$REMOTE_HOME/.claude/settings.warphole-local.json"
  printf -v settings_q '%q' "$settings_path"
  printf -v backup_q '%q' "$backup_path"

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
  printf '%s/%s.session\n' "$STATE_DIR" "$1"
}

_remember_remote_session() {
  local encoded_path="$1"
  local session="$2"
  local state_file
  state_file=$(_state_file_for_project "$encoded_path")
  mkdir -p "$STATE_DIR"
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
  provider_ssh "tmux has-session -t $(printf '%q' "warphole-${session}") 2>/dev/null"
}

_list_remote_sessions_for_project() {
  local encoded_path="$1"
  local prefix_q
  printf -v prefix_q '%q' "warphole-${encoded_path}__"
  provider_ssh "tmux list-sessions -F '#S' 2>/dev/null | awk -v prefix=$prefix_q 'index(\$0, prefix) == 1 { sub(/^warphole-/, \"\", \$0); print }'" 2>/dev/null | tr -d '\r'
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

cmd_setup() {
  echo "agent-warphole — Setup"
  echo ""
  read -rp "  Fly.io app name: " app
  [[ -n "$app" ]] || { echo "App name required." >&2; exit 1; }

  cat > "$CONF" <<EOF
WARPHOLE_AGENT=claude
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
  local msg="${*:-}"
  local session encoded_path remote_claude_path project_path resume_cmd
  local remote_claude_path_q project_path_q pwd_q tmux_session_q resume_cmd_q
  session=$(agent_session_id) \
    || { echo "No active session — open a project in Claude first." >&2; exit 1; }
  encoded_path="${session%__*}"

  printf '\n  session   %s\n  remote    %s\n\n' "${session:0:16}" "$WARPHOLE_PROVIDER"

  provider_ssh "true" >/dev/null \
    || { echo "Remote unreachable — is the VM running? Try: fly status -a ${FLY_APP:-}" >&2; exit 1; }

  echo "Syncing…"
  local sync_ok=1
  while IFS=$'\t' read -r path dest; do
    dest="${dest:-$path}"
    [[ -e "$path" ]] || continue
    printf '    %s\n' "$path"
    provider_rsync "$path" "$dest" || { echo "  rsync failed: $path" >&2; sync_ok=0; }
  done < <(agent_sync_paths)

  # Sync phone server files to remote
  if [[ -d "$DIR/phone" ]]; then
    printf '    %s\n' "$DIR/phone"
    provider_rsync "$DIR/phone" "/opt/warphole/phone" \
      || { echo "  rsync failed: phone server" >&2; sync_ok=0; }
  fi

  [[ $sync_ok -eq 1 ]] || { echo "Sync errors above — aborting to protect remote state." >&2; exit 1; }

  remote_claude_path="$REMOTE_HOME/.claude"
  project_path="$PWD"
  printf -v remote_claude_path_q '%q' "$remote_claude_path"
  printf -v project_path_q '%q' "$project_path"
  provider_ssh "mkdir -p $remote_claude_path_q && chown -R user:user $remote_claude_path_q $project_path_q" \
    || { echo "Remote ownership fix failed." >&2; exit 1; }

  _remote_disable_hooks

  printf '\nLaunching on remote…\n'

  resume_cmd=$(agent_resume_cmd "$session" "$msg")
  printf -v pwd_q '%q' "$PWD"
  printf -v tmux_session_q '%q' "warphole-${session}"
  printf -v resume_cmd_q '%q' "$resume_cmd"
  provider_ssh "
    tmux kill-session -t $tmux_session_q 2>/dev/null || true
    tmux new-session -d -s $tmux_session_q -c $pwd_q
    tmux send-keys -t $tmux_session_q -l -- $resume_cmd_q
    tmux send-keys -t $tmux_session_q Enter
  "

  _remember_remote_session "$encoded_path" "$session"

  # (Re)start phone server pointed at the new session.
  # HOME=$REMOTE_HOME so Path.home() in controller.py finds the right .claude dir.
  # Always named 'warphole-phone' — one active session per VM.
  local phone_cmd_q
  printf -v phone_cmd_q '%q' "HOME=$REMOTE_HOME python3 /opt/warphole/phone/controller.py --session warphole-${session} --project $PWD --host 0.0.0.0 --port 8420"
  provider_ssh "
    tmux kill-session -t warphole-phone 2>/dev/null || true
    tmux new-session -d -s warphole-phone
    tmux send-keys -t warphole-phone -l -- $phone_cmd_q
    tmux send-keys -t warphole-phone Enter
  " || echo "  warning: phone server could not start on remote" >&2

  _audit_log "go" "session" "$session" "remote" "$WARPHOLE_PROVIDER"

  printf '\n  Phone UI: https://%s.fly.dev\n\n' "${FLY_APP:-<app>}"

  provider_attach "$session"
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
  remote_project="$PWD"
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

    if [[ "$path" == "$HOME/.claude/settings.json" ]]; then
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

  if [[ -n "$remote_session" ]]; then
    remote_uuid="${remote_session##*__}"
    touch "$HOME/.claude/projects/$encoded_path/$remote_uuid.jsonl" 2>/dev/null || true
    echo "  preferred local resume session → $remote_session"
  else
    echo "  warning: could not identify remote session id; future resume may prefer the local suck session"
  fi

  printf '\nStopping remote Claude…\n'
  if [[ -n "$remote_session" ]]; then
    provider_ssh "tmux kill-session -t $(printf '%q' "warphole-${remote_session}") 2>/dev/null || true"
  else
    echo "  no remote tmux session found"
  fi

  # Return phone server to waiting mode
  provider_ssh "
    tmux kill-session -t warphole-phone 2>/dev/null || true
    tmux new-session -d -s warphole-phone /usr/local/bin/phone-start.sh 2>/dev/null || true
  " 2>/dev/null || true
  echo "  phone server → waiting mode"

  _clear_preferred_remote_session "$encoded_path"
  echo "  remote tmux session stopped"

  _audit_log "suck" "session" "${remote_session:-$session}" "remote" "$WARPHOLE_PROVIDER"
}

cmd_list() {
  printf '\n  project   %s\n\n' "$PWD"

  provider_ssh "true" >/dev/null 2>&1 \
    || { echo "  Remote unreachable — is the VM running?" >&2; exit 1; }

  local encoded_path sessions=()
  encoded_path=$(echo "$PWD" | sed 's|/|-|g')

  while IFS= read -r s; do
    [[ -n "$s" ]] && sessions+=("$s")
  done < <(_list_remote_sessions_for_project "$encoded_path")

  if [[ ${#sessions[@]} -eq 0 ]]; then
    echo "  No remote sessions for this project."
  else
    echo "  Remote sessions:"
    for s in "${sessions[@]}"; do
      local status_indicator="running"
      printf '    %-16s  %s\n' "${s:0:16}…" "$status_indicator"
    done
  fi
  echo ""
  _audit_log "list" "remote" "$WARPHOLE_PROVIDER"
}

cmd_status() {
  local session encoded_path preferred

  session=$(agent_session_id 2>/dev/null) || session=""
  encoded_path=$(echo "$PWD" | sed 's|/|-|g')

  printf '\n  project   %s\n' "$PWD"
  [[ -n "$session" ]] && printf '  session   %s\n' "${session:0:40}"

  if ! provider_ssh "true" >/dev/null 2>&1; then
    printf '  remote    unreachable\n\n'
    return 0
  fi

  preferred=$(_preferred_remote_session "$encoded_path" 2>/dev/null || true)
  if [[ -n "$preferred" ]] && _remote_session_exists "$preferred" >/dev/null 2>&1; then
    printf '  remote    running\n'
    printf '  phone     fly proxy 8420:8420 -a %s && open http://localhost:8420\n' "${FLY_APP:-<app>}"
  else
    printf '  remote    stopped\n'
  fi
  echo ""
}

cmd_log() {
  local n=20 project_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--lines) n="$2"; shift 2 ;;
      --project)  project_filter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ ! -f "$AUDIT_LOG" ]]; then
    echo "No audit log at $AUDIT_LOG"
    return 0
  fi

  tail -n "$n" "$AUDIT_LOG" | python3 -c "
import json, sys

project_filter = sys.argv[1] if len(sys.argv) > 1 else ''
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        if project_filter and project_filter not in e.get('project',''):
            continue
        ts = e.get('ts','?')
        op = e.get('op','?').upper()
        project = e.get('project','?')
        extras = {k:v for k,v in e.items() if k not in ('ts','op','project')}
        extras_str = '  ' + '  '.join(f'{k}={v}' for k,v in extras.items()) if extras else ''
        proj_short = project.split('/')[-1] if '/' in project else project
        print(f'{ts}  {op:<8s}  {proj_short}{extras_str}')
    except Exception:
        print(f'  {line}')
" "$project_filter"
}

cmd_skills() {
  local subcmd="${1:-list}"
  shift || true

  case "$subcmd" in
    install)
      local src="${1:?Usage: warphole skills install <file.md>}"
      [[ -f "$src" ]] || { echo "File not found: $src" >&2; exit 1; }
      local name
      name=$(basename "$src" .md)
      local dest="$HOME/.claude/commands/${name}.md"
      cp "$src" "$dest"
      printf '  installed → %s\n' "$dest"
      _registry_update "skills" "$name" "{\"name\":\"$name\",\"path\":\"$dest\"}"
      ;;
    list)
      echo "  Skills in ~/.claude/commands/:"
      local found=0
      for f in "$HOME/.claude/commands/"*.md; do
        [[ -f "$f" ]] || continue
        printf '    %s\n' "$(basename "$f" .md)"
        found=1
      done
      [[ $found -eq 1 ]] || echo "    (none)"
      ;;
    remove)
      local name="${1:?Usage: warphole skills remove <name>}"
      rm -f "$HOME/.claude/commands/${name}.md"
      printf '  removed: %s\n' "$name"
      _registry_remove "skills" "$name"
      ;;
    *)
      echo "Usage: warphole skills [install <file>|list|remove <name>]" >&2
      exit 1
      ;;
  esac
}

cmd_mcp() {
  local subcmd="${1:-list}"
  shift || true

  case "$subcmd" in
    add)
      local name="${1:?Usage: warphole mcp add <name> <command>}"
      shift
      local cmd_str="$*"
      [[ -n "$cmd_str" ]] || { echo "Command required." >&2; exit 1; }
      _settings_mcp_add "$name" "$cmd_str"
      printf '  added MCP server: %s\n' "$name"
      _registry_update "mcp" "$name" "{\"name\":\"$name\",\"command\":\"$cmd_str\"}"
      ;;
    list)
      echo "  MCP servers in ~/.claude/settings.json:"
      python3 -c "
import json, os, sys
path = os.path.expanduser('~/.claude/settings.json')
if not os.path.exists(path): sys.exit(0)
data = json.loads(open(path).read())
servers = data.get('mcpServers', {})
if not servers:
    print('    (none)')
for name, conf in servers.items():
    parts = [conf.get('command', '')] + conf.get('args', [])
    print(f'    {name}: {\" \".join(p for p in parts if p)}')
"
      ;;
    remove)
      local name="${1:?Usage: warphole mcp remove <name>}"
      _settings_mcp_remove "$name"
      printf '  removed MCP server: %s\n' "$name"
      _registry_remove "mcp" "$name"
      ;;
    sync-to-remote)
      # Sync local MCP config to remote settings.json (called internally by cmd_go)
      python3 -c "
import json, os, sys
local_path = os.path.expanduser('~/.claude/settings.json')
if not os.path.exists(local_path): sys.exit(0)
data = json.loads(open(local_path).read())
servers = data.get('mcpServers', {})
if not servers: sys.exit(0)
for name, conf in servers.items():
    parts = [conf.get('command','')] + conf.get('args',[])
    print(f'{name}\t{chr(32).join(p for p in parts if p)}')
" | while IFS=$'\t' read -r name cmd_str; do
        echo "  syncing MCP: $name"
        # Update remote settings via SSH
        local remote_settings_q cmd_str_q
        printf -v remote_settings_q '%q' "$REMOTE_HOME/.claude/settings.json"
        printf -v cmd_str_q '%q' "$cmd_str"
        provider_ssh "python3 -c \"
import json, sys, os
path = '$REMOTE_HOME/.claude/settings.json'
data = {}
if os.path.exists(path):
    try: data = json.loads(open(path).read())
    except: pass
if 'mcpServers' not in data: data['mcpServers'] = {}
parts = $cmd_str_q.split()
data['mcpServers']['$name'] = {'command': parts[0], 'args': parts[1:]} if parts else {'command': ''}
open(path, 'w').write(json.dumps(data, indent=2) + chr(10))
\"" || true
      done
      ;;
    *)
      echo "Usage: warphole mcp [add <name> <command>|list|remove <name>]" >&2
      exit 1
      ;;
  esac
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-go}" in
  setup)
    cmd_setup
    ;;
  list)
    [[ -f "$CONF" ]] || { echo "Not configured — run: warphole setup" >&2; exit 1; }
    source "$CONF"
    source "$DIR/agents/${WARPHOLE_AGENT}.sh"
    source "$DIR/providers/${WARPHOLE_PROVIDER}.sh"
    cmd_list
    ;;
  status)
    [[ -f "$CONF" ]] || { echo "Not configured — run: warphole setup" >&2; exit 1; }
    source "$CONF"
    source "$DIR/agents/${WARPHOLE_AGENT}.sh"
    source "$DIR/providers/${WARPHOLE_PROVIDER}.sh"
    cmd_status
    ;;
  log)
    shift
    cmd_log "$@"
    ;;
  skills)
    shift
    cmd_skills "$@"
    ;;
  mcp)
    shift
    cmd_mcp "$@"
    ;;
  suck)
    [[ -f "$CONF" ]] || { echo "Not configured — run: warphole setup" >&2; exit 1; }
    source "$CONF"
    source "$DIR/agents/${WARPHOLE_AGENT}.sh"
    source "$DIR/providers/${WARPHOLE_PROVIDER}.sh"
    shift || true
    cmd_suck "$@"
    ;;
  *)
    [[ -f "$CONF" ]] || { echo "Not configured — run: warphole setup" >&2; exit 1; }
    source "$CONF"
    source "$DIR/agents/${WARPHOLE_AGENT}.sh"
    source "$DIR/providers/${WARPHOLE_PROVIDER}.sh"
    [[ "${1:-}" == "go" ]] && shift || true
    cmd_go "$@"
    ;;
esac
