Run the following command and show its full output to the user:

```bash
bash ~/.claude/warphole/warphole.sh $ARGUMENTS
```

If warphole completes successfully (exit 0):
- Show the attach command from the output
- Tell the user their session is now live on the remote VM
- End this local session

If it fails, show the error and keep the session alive so the user can fix the issue.
