#!/usr/bin/env bash
# Claude Code agent adapter.
#
# Knows where Claude stores conversations and how to resume them.
# Swap this file to support a different agent (Codex, Gemini, etc.)
# without touching teleport.sh or any provider.

agent_session_id() {
  # Claude names each project's session directory by encoding its absolute path:
  # /Users/g/code/myapp → -Users-g-code-myapp
  # We use this as our session ID — stable across conversations, unique per project.
  echo "$PWD" | sed 's|/|-|g'
}

agent_sync_paths() {
  local session_dir="$HOME/.claude/projects/$(agent_session_id)"

  # Everything Claude needs to pick up where it left off:
  # conversation history, user config, project memory, and the code itself.
  printf '%s\n' \
    "$session_dir" \
    "$HOME/.claude/settings.json" \
    "$HOME/.claude/CLAUDE.md" \
    "$PWD"
}

agent_resume_cmd() {
  # --continue resumes the most recently active conversation in the project dir.
  # Since we just synced that dir over, this lands exactly mid-conversation.
  echo "claude --continue"
}
