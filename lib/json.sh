#!/usr/bin/env bash
# JSON helpers for agent-warphole.
#
# All inline-Python JSON manipulation lives here so warphole.sh stays clean.
# Requires: python3, WARPHOLE_AUDIT_LOG, WARPHOLE_REGISTRY from constants.sh.

# ── Audit log ────────────────────────────────────────────────────────────────

_audit_log() {
  local op="$1"; shift
  python3 -c "
import json, sys, time
entry = {'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'op': sys.argv[1], 'project': sys.argv[2]}
args = sys.argv[3:]
for i in range(0, len(args)-1, 2):
    entry[args[i]] = args[i+1]
print(json.dumps(entry))
" "$op" "$PWD" "$@" >> "$WARPHOLE_AUDIT_LOG" 2>/dev/null || true
}

# ── Registry (skills + MCP metadata) ────────────────────────────────────────

_registry_update() {
  python3 -c "
import json, sys, os
path = sys.argv[3]
data = {}
if os.path.exists(path):
    try: data = json.loads(open(path).read())
    except: pass
section, name, entry = sys.argv[1], sys.argv[2], json.loads(sys.argv[4])
if section not in data: data[section] = {}
data[section][name] = entry
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1" "$2" "$WARPHOLE_REGISTRY" "$3"
}

_registry_remove() {
  python3 -c "
import json, sys, os
path = sys.argv[3]
if not os.path.exists(path): sys.exit(0)
data = json.loads(open(path).read())
data.get(sys.argv[1], {}).pop(sys.argv[2], None)
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1" "$2" "$WARPHOLE_REGISTRY"
}

# ── settings.json MCP manipulation ──────────────────────────────────────────

_settings_mcp_add() {
  local settings_path="${2:-$HOME/.claude/settings.json}"
  python3 -c "
import json, sys, os
name, cmd_str, path = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path):
    try: data = json.loads(open(path).read())
    except: pass
if 'mcpServers' not in data: data['mcpServers'] = {}
parts = cmd_str.split()
data['mcpServers'][name] = {'command': parts[0], 'args': parts[1:]} if parts else {'command': ''}
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1" "$3" "$settings_path"
}

_settings_mcp_remove() {
  local settings_path="${2:-$HOME/.claude/settings.json}"
  python3 -c "
import json, sys, os
path = sys.argv[2]
if not os.path.exists(path): sys.exit(0)
data = json.loads(open(path).read())
data.get('mcpServers', {}).pop(sys.argv[1], None)
open(path, 'w').write(json.dumps(data, indent=2) + '\n')
" "$1" "$settings_path"
}

_settings_mcp_list() {
  local settings_path="${1:-$HOME/.claude/settings.json}"
  python3 -c "
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path): sys.exit(0)
data = json.loads(open(path).read())
servers = data.get('mcpServers', {})
if not servers:
    print('    (none)')
for name, conf in servers.items():
    parts = [conf.get('command', '')] + conf.get('args', [])
    print(f'    {name}: {\" \".join(p for p in parts if p)}')
" "$settings_path"
}

# Sync local MCP servers to a remote settings.json via provider_ssh.
# Reads local settings, writes each server entry to the remote file.
_settings_mcp_sync_to_remote() {
  local remote_settings_path="$1"
  python3 -c "
import json, os, sys
path = os.path.expanduser('~/.claude/settings.json')
if not os.path.exists(path): sys.exit(0)
data = json.loads(open(path).read())
servers = data.get('mcpServers', {})
if not servers: sys.exit(0)
for name, conf in servers.items():
    parts = [conf.get('command','')] + conf.get('args',[])
    print(f'{name}\t{chr(32).join(p for p in parts if p)}')
" | while IFS=$'\t' read -r name cmd_str; do
    echo "  syncing MCP: $name"
    _settings_mcp_add "$name" "$remote_settings_path" "$cmd_str"
  done
}

# ── settings.json hook stripping ─────────────────────────────────────────────

_json_strip_hooks() {
  local settings_path="$1"
  local backup_path="$2"
  local settings_q backup_q
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
