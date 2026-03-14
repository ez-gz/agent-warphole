# Claude Teleport — Design Specification

## Guiding Principle

**Simplicity over completeness.** Every layer should be so clean that a new provider or agent adapter fits in ~30 lines. No framework. No dependencies. Shell + rsync + SSH.

---

## What It Does

`/teleport` migrates a live local coding-agent session to a remote always-on VM.
The local session ends. The remote picks up mid-conversation.

---

## The Two Abstractions

The whole system is two orthogonal concerns:

```
┌─────────────────────────────────────────────────┐
│  AGENT  — what are we moving?                   │
│  knows: session format, paths to sync, how      │
│  to resume. Claude today, Codex tomorrow.        │
├─────────────────────────────────────────────────┤
│  PROVIDER — where are we moving it?             │
│  knows: how to SSH in, how to rsync there.      │
│  Fly.io today, generic SSH or GCP tomorrow.     │
└─────────────────────────────────────────────────┘
```

`teleport.sh` is the thin orchestrator that calls into both. It has no opinion about agents or clouds.

---

## Layer Interfaces

Each adapter exports exactly these functions. Nothing more.

### Agent interface

```bash
# agents/claude.sh  (or agents/codex.sh, etc.)

agent_session_id()   # → the current session's ID string
agent_sync_paths()   # → newline-delimited list of local paths to copy
agent_resume_cmd()   # → the command to run on the remote to resume
```

### Provider interface

```bash
# providers/fly.sh  (or providers/ssh.sh, etc.)

provider_ssh()       # runs a command on the remote:  provider_ssh "tmux ..."
provider_rsync()     # syncs paths to remote:         provider_rsync <src> <dest>
provider_attach()    # prints the attach command for the user to copy-paste
```

That's the contract. Swap either side without touching the other.

---

## Core Flow (`teleport.sh`)

The orchestrator. ~60 lines.

```
1. source the configured agent adapter   (agents/$AGENT.sh)
2. source the configured provider adapter (providers/$PROVIDER.sh)

3. SESSION_ID=$(agent_session_id)
4. PATHS=$(agent_sync_paths)

5. ping remote — abort cleanly if unreachable

6. for each path in PATHS:
     provider_rsync "$path" "$path"   # same path both sides (path parity, see below)

7. provider_ssh "$(agent_resume_cmd $SESSION_ID)"

8. provider_attach $SESSION_ID        # print: "To connect: fly ssh console ..."

9. exit 0  — local session ends
```

---

## Path Parity

Claude Code hashes the absolute project path to locate session files:

```
/Users/g/Desktop/projects/my-app  →  ~/.claude/projects/-Users-g-Desktop-projects-my-app/
```

The remote must reproduce the identical path or the session won't load.
`teleport setup` creates the path skeleton on the VM once. After that, `rsync src dest` with identical paths on both sides just works.

This is a constraint of Claude's session model, not of teleport. A future agent adapter (e.g. Codex) might not have this constraint — that's why it lives in the agent layer.

---

## Claude Agent Adapter (`agents/claude.sh`)

```bash
agent_session_id() {
  # most-recently-modified project dir = active session
  ls -t ~/.claude/projects/ | head -1
}

agent_sync_paths() {
  local session=$(agent_session_id)
  echo "$HOME/.claude/projects/$session"   # conversation history (JSONL)
  echo "$HOME/.claude/settings.json"       # user config
  echo "$HOME/.claude/CLAUDE.md"           # project memory
  echo "$PWD"                              # the project itself
}

agent_resume_cmd() {
  # claude --resume drops back into the exact conversation turn
  echo "cd $PWD && claude --resume $1"
}
```

---

## Fly.io Provider Adapter (`providers/fly.sh`)

```bash
# Requires: flyctl installed and authenticated locally, app name in config

provider_ssh() {
  fly ssh console -a "$FLY_APP" -C "$1"
}

provider_rsync() {
  # fly proxy opens a local tunnel on a spare port; rsync goes through it
  fly proxy 2222:22 -a "$FLY_APP" &
  rsync -az --delete "$1" "root@localhost:$2" -e "ssh -p 2222 -o StrictHostKeyChecking=no"
  kill %1  # close proxy
}

provider_attach() {
  echo ""
  echo "  Session is live. Attach with:"
  echo "  fly ssh console -a $FLY_APP -C 'tmux attach -t teleport-$1'"
  echo ""
}
```

---

## Configuration (`~/.claude/teleport.json`)

Minimal. Just enough to select adapters and pass them their one or two required values.

```json
{
  "agent":    "claude",
  "provider": "fly.io",

  "fly.io": { "app": "my-claude-vm" },
  "ssh":    { "host": "my-vm.example.com", "user": "g" }
}
```

Adding a provider means adding one block here and one file in `providers/`.

---

## Multi-Session Isolation

Each teleported session gets a tmux session named `teleport-<session-id>`.
Different projects land in different absolute paths, so there's no filesystem collision on the VM.

```
Remote VM
  tmux: teleport-a1b2c3  →  /Users/g/Desktop/projects/app-one
  tmux: teleport-d4e5f6  →  /Users/g/Desktop/projects/app-two
```

---

## MVP File Layout

```
claude-teleport/
├── teleport.sh          # orchestrator — sources adapters, runs the flow
├── agents/
│   └── claude.sh        # Claude Code session adapter
├── providers/
│   └── fly.sh           # Fly.io provider
└── skill/
    └── teleport.md      # Claude Code /teleport skill registration
```

That's it. `setup.sh` and `/teleport list` are Phase 2.

---

## Error Handling

Fail loud, fail safe. If anything goes wrong before step 7 (remote exec), the local session is untouched.

| Failure | Behavior |
|---|---|
| VM unreachable | abort — local session continues, no damage done |
| rsync fails | abort — remote partial state is overwritten on retry |
| Remote agent fails to start | print error + manual attach command |

---

## What's Explicitly Out of Scope (MVP)

- `/teleport list`, `/teleport kill` — Phase 2
- Bidirectional sync (teleport back to local) — Phase 3
- `.teleportignore` — use `.gitignore` for now; rsync respects it via `--filter`
- On-demand VM provisioning — always-on only; setup is manual for now

---

## Future Agent Adapters

Adding Codex (or any other agent) means writing `agents/codex.sh` with the same three functions. If Codex stores sessions differently, that complexity stays inside the adapter — teleport.sh never changes.

```bash
# agents/codex.sh — hypothetical
agent_session_id() { cat .codex/session_id; }
agent_sync_paths() { echo "$PWD"; echo "$HOME/.codex"; }
agent_resume_cmd() { echo "cd $PWD && codex --session $1"; }
```
