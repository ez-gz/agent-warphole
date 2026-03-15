# agent-warphole

Warphole a live Claude Code session to a remote VM. Full conversation context moves with it. Local session ends.

Anthropic's built-in `/teleport` only pulls web sessions *down* to local. This is the other direction — push any local session up to your own VM.

Terminal attach is local best-effort. There is no universal macOS API for "open a tab in whatever terminal currently hosts this PTY", so Ghostty/Terminal/iTerm use app-specific launch paths and unknown terminals fall back.

## Install

```bash
git clone https://github.com/yourname/agent-warphole ~/src/agent-warphole
cp ~/src/agent-warphole/skill/warphole.md ~/.claude/commands/warphole.md
~/src/agent-warphole/deploy/setup.sh   # provision fly.io VM, write config (~5 min, once)
```

Requires [flyctl](https://fly.io/docs/hands-on/install-flyctl/) + a Fly.io account.

`deploy/setup.sh` now prompts for an optional persistent volume size.
Leave it blank for a single VM with no attached volume.
It also walks the one-time remote Claude auth/onboarding step.
Remote warphole runs strip `hooks` from the active remote `settings.json` so local-only hook tooling does not break the VM session.

Optional local Ghostty sizing:
`WARPHOLE_GHOSTTY_WINDOW_WIDTH=140`
`WARPHOLE_GHOSTTY_WINDOW_HEIGHT=45`

## Use

Inside any Claude Code session:

```
/warphole
/warphole suck
```

`/warphole` syncs, starts the remote tmux session, and opens the attach command in the current host terminal when it can. Ghostty falls back to a new Ghostty window and can be sized via the env vars above.
This attach behavior is local setup/UX, not part of the remote VM contract.

`/warphole suck` pulls remote project files, Claude session files, and Claude config back to local, then stops the remote tmux session. Default behavior preserves conflicting local project files and writes remote copies under `~/.claude/warphole-incoming/...`. Use `/warphole suck --clobber` to overwrite local project state from remote.
If you have multiple remote sessions for the same project, run `/warphole suck <session-id>` to pick the exact one.

## Config

`~/.claude/warphole.conf` — written by setup.

```bash
WARPHOLE_AGENT=claude     # or: codex
WARPHOLE_PROVIDER=fly
FLY_APP=my-warphole-vm
REMOTE_HOME=/home/user
```

Verify setup: `./smoke_test.sh --remote`
