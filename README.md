# claude-teleport

Teleport a live Claude Code session to a remote VM. Full conversation context moves with it. Local session ends.

## Install

```bash
git clone https://github.com/yourname/claude-teleport ~/.claude/teleport
cp ~/.claude/teleport/skill/teleport.md ~/.claude/commands/teleport.md
~/.claude/teleport/deploy/setup.sh   # provision fly.io VM, write config (~5 min, once)
```

Requires [flyctl](https://fly.io/docs/hands-on/install-flyctl/) + a Fly.io account.

## Use

Inside any Claude Code session:

```
/teleport
```

Then attach to the remote: `fly ssh console -a <app> -C 'tmux attach -t teleport-<id>'`

## Config

`~/.claude/teleport.conf` — written by setup.

```bash
TELEPORT_AGENT=claude     # or: codex
TELEPORT_PROVIDER=fly
FLY_APP=my-claude-vm
```

Verify setup: `./smoke_test.sh --remote`
