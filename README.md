# agent-warphole

Warphole a live Claude Code session to a remote VM. Full conversation context moves with it. Local session ends.

Anthropic's built-in `/teleport` only pulls web sessions *down* to local. This is the other direction — push any local session up to your own VM.

## Install

```bash
git clone https://github.com/yourname/agent-warphole ~/.claude/warphole
cp ~/.claude/warphole/skill/warphole.md ~/.claude/commands/warphole.md
~/.claude/warphole/deploy/setup.sh   # provision fly.io VM, write config (~5 min, once)
```

Requires [flyctl](https://fly.io/docs/hands-on/install-flyctl/) + a Fly.io account.

## Use

Inside any Claude Code session:

```
/warphole
```

Then attach to the remote: `fly ssh console -a <app> -C 'tmux attach -t warphole-<id>'`

## Config

`~/.claude/warphole.conf` — written by setup.

```bash
WARPHOLE_AGENT=claude     # or: codex
WARPHOLE_PROVIDER=fly
FLY_APP=my-warphole-vm
```

Verify setup: `./smoke_test.sh --remote`
