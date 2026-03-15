---
name: warphole
description: Use when the user starts a message with `warphole` or types `/warphole`, asks to teleport or warphole the current Claude or Codex session to the remote VM, or asks to pull remote warphole state back locally with `warphole suck`. Runs the local warphole shell entrypoint and reports the result. If the message starts with `warphole`, treat everything after that prefix as shell arguments for the warphole script, not as a separate local coding task.
---

# Warphole

When the user asks for `/warphole`, starts a message with `warphole`, or describes teleporting the current Claude or Codex session to the remote VM:

1. Run:
```bash
bash ~/.claude/warphole/warphole.sh [arguments...]
```

2. Map the user's request to arguments:
- `warphole` or `/warphole` -> no extra args
- `warphole suck` or `/warphole suck` -> `suck`
- `warphole suck --clobber` or `/warphole suck --clobber` -> `suck --clobber`
- `warphole claude ...` or `warphole codex ...` -> pass those explicit overrides through unchanged
- `warphole <freeform text>` -> pass the trailing text through as the opening prompt

Important:
- If the message starts with `warphole `, do not also try to perform the trailing text as a normal local Codex task.
- Treat the rest of the message as input to `warphole.sh`.
- Example: `warphole summarize this repo` means run `bash ~/.claude/warphole/warphole.sh "summarize this repo"`; it does not mean summarize the repo locally.

3. On success:
- If this was a `suck` request, tell the user the remote state was pulled back locally and the remote tmux session was stopped. Keep the local session alive.
- Otherwise, tell the user the session is live on the remote VM and a terminal tab/window may have opened for attach. The local session should end if the host agent treats clean exit that way.

4. On failure:
- Show the command error briefly and keep the local session alive.

Notes:
- Prefer the repo-installed entrypoint at `~/.claude/warphole/warphole.sh`.
- Do not reimplement the teleport logic in the skill. The skill is only a thin trigger/dispatcher.
- If agent auto-detection is ambiguous, suggest the explicit forms `/warphole claude` or `/warphole codex`.
- Codex may reject unknown slash commands before skills run. If `/warphole` is rejected by the CLI parser, tell the user to use `warphole ...` without the slash instead.
