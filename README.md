# agent-warphole

Warphole a live Claude Code session to a remote VM. Full conversation context moves with it. Local session ends.

Anthropic's built-in `/teleport` only pulls web sessions *down* to local. This is the other direction — push any local session up to your own VM.

## Install

```bash
git clone https://github.com/ez-gz/agent-warphole ~/src/agent-warphole
cp ~/src/agent-warphole/skill/warphole.md ~/.claude/commands/warphole.md
~/src/agent-warphole/deploy/setup.sh   # provision fly.io VM, write config (~5 min, once)
```

Requires [flyctl](https://fly.io/docs/hands-on/install-flyctl/) + a Fly.io account.

`deploy/setup.sh` prompts for an optional persistent volume size. Leave blank for no attached volume. It also walks the one-time remote Claude auth/onboarding step.

Remote warphole sessions strip `hooks` from the active remote `settings.json` so local-only hook tooling doesn't break the VM session.

Optional Ghostty window sizing:
```bash
WARPHOLE_GHOSTTY_WINDOW_WIDTH=140
WARPHOLE_GHOSTTY_WINDOW_HEIGHT=45
```

## Use

Inside any Claude Code session:

```
/warphole                  # sync, launch on remote, attach terminal
/warphole execute the spec # sync, launch, send opening prompt
/warphole suck             # pull remote state back, stop remote session
```

`/warphole` syncs project + Claude config to the VM, starts a tmux session, launches Claude there, starts the phone server, and opens the terminal attach in your current host terminal (Ghostty gets a new sized window; unknown terminals fall back to printing the attach command).

`/warphole suck` pulls remote project files and Claude session state back to local, then stops the remote tmux session. Default behavior preserves conflicting local files and writes remote copies under `~/.claude/warphole-incoming/`. Use `--clobber` to overwrite local from remote. Pass a session ID to pick from multiple remote sessions for the same project.

## Config

`~/.claude/warphole.conf` — written by setup.

```bash
WARPHOLE_AGENT=claude
WARPHOLE_PROVIDER=fly
FLY_APP=my-warphole-vm
REMOTE_HOME=/home/user
```

Verify everything: `./smoke_test.sh --remote`

## Phone UI

A mobile-optimized chat view that reads the Claude conversation directly and lets you send messages from your phone. Runs co-located with Claude — on the remote VM after `/warphole`, or locally via `phone_ui.sh`.

### Remote access (public HTTPS)

When you run `/warphole`, the phone server starts automatically on the remote VM and is publicly accessible:

```
https://my-warphole-vm.fly.dev
```

No proxy or VPN required. Auth is on the roadmap — for now it's open, suitable for personal demo use.

The server starts at VM boot in *waiting mode* (empty conversation, `has_session: false`). The UI polls every 2.2 seconds and automatically transitions to the live conversation once `/warphole` fires.

### Local access

```bash
./phone_ui.sh                            # auto-detects a tmux pane running claude
./phone_ui.sh --session my-session       # explicit tmux session name
./phone_ui.sh --host 0.0.0.0 --port 8420
```

### Web UI features

- **Chat** — full conversation, markdown-rendered with code blocks
- **Term** — raw tmux terminal output (last 300 lines)
- **Log** — warphole audit history (go, suck, list) with timestamps
- **Voice input** — browser speech recognition fills the prompt box before send

### iOS app

A native SwiftUI app in `ios/WarpholPhone/` with live streaming dictation:

- Words appear in the input field **as you speak** (not after you stop)
- Quick-key chips: `esc`, `ctrl+c`, `↑`, `↓` — one tap sends the key to the remote tmux session
- Server URL configurable in-app (default: your Fly.io app)

Setup: create a new Xcode iOS app project, drop the files from `ios/WarpholPhone/` in, add the `Info.plist` permission strings, build. See `ios/README.md` for the full 2-minute walkthrough.

## Workstream management

```bash
warphole list                 # list all remote sessions for this project
warphole status               # check if this project has a live remote session
warphole log                  # audit log of go/suck/list operations
warphole log -n 50            # last 50 entries
warphole log --project myapp  # filter by project name
```

## Skills and MCP

Install once, synced to remote on every `warphole go`.

```bash
# Slash-command skills
warphole skills install path/to/my-skill.md   # copies to ~/.claude/commands/
warphole skills list
warphole skills remove my-skill

# MCP servers
warphole mcp add my-server npx @my/mcp-server
warphole mcp add filesystem uvx mcp-server-filesystem /home/user/projects
warphole mcp list
warphole mcp remove my-server
```

Skills live in `~/.claude/commands/`. MCP servers are written to `~/.claude/settings.json`. Registry persisted at `~/.claude/warphole-registry.json`.
