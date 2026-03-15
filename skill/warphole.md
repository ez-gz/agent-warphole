Run this command:

```bash
bash ~/.claude/warphole/warphole.sh $ARGUMENTS 2>&1
```

If `ARGUMENTS` begins with `suck` and the command succeeds, tell the user the remote state was pulled back locally and the remote tmux session was stopped. Keep the local session alive.

Otherwise, if it succeeds, tell the user their session is live and a terminal tab or window has opened with the remote session. End this local session.

If it fails, show the error and keep the local session alive.
