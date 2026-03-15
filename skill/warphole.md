Run this command and report the result:

```bash
bash ~/.claude/warphole/warphole.sh $ARGUMENTS 2>&1
```

Interpret the output based on the subcommand:

**`suck`** — remote state was pulled back locally and the remote session stopped. Keep local session alive. Tell the user their files are back and the remote is stopped.

**`list`** — show the user the remote sessions printed by the command.

**`status`** — show the user whether the remote is running and the phone URL if available.

**`log`** — show the user the audit entries printed by the command.

**`skills install/list/remove`** — confirm the skill operation completed.

**`mcp add/list/remove`** — confirm the MCP operation completed. Remind the user that changes sync to the remote on the next `/warphole`.

**`go` (default, no subcommand)** — if it succeeds, tell the user:
1. Their session is live on the remote VM
2. A terminal window has opened with the remote session
3. The phone UI URL printed in the output (https://….fly.dev)

Then end this local session.

If any command fails, show the error and keep the local session alive.
