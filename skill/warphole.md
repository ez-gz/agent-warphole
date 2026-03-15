Run one of these commands:

- If there are no arguments:
```bash
bash ~/.claude/warphole/warphole.sh 2>&1
```

- If the user asked for `suck`, pass `suck` arguments through as shell words:
```bash
bash ~/.claude/warphole/warphole.sh suck [--clobber] [session-id] 2>&1
```

- If the user explicitly asked for `claude` or `codex`, pass that override through as shell words:
```bash
bash ~/.claude/warphole/warphole.sh claude ... 2>&1
bash ~/.claude/warphole/warphole.sh codex ... 2>&1
```

- Otherwise, treat the trailing text as a single opening prompt argument and quote it:
```bash
bash ~/.claude/warphole/warphole.sh "<full trailing user text>" 2>&1
```

Do not interpolate raw trailing text into the shell unquoted.

If `ARGUMENTS` begins with `suck` and the command succeeds, tell the user the remote state was pulled back locally and the remote tmux session was stopped. Keep the local session alive.

Otherwise, if it succeeds, tell the user their session is live and a terminal tab or window has opened with the remote session. End this local session.

If it fails, show the error and keep the local session alive.
