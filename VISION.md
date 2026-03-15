# agent-warphole — direction

The goal is a complete stack for running coding agents from anywhere, on any device, across any agent. Four pillars:

---

## 1. Workstream teleport / reclaim

The core primitive. A **workstream** is a feature or task being actively built — not a raw shell session. You push it to a remote VM to run unattended, and pull it back when you want it local again.

- `/warphole` — push local session (Claude, Codex, etc.) to a Fly VM. Full context moves with it. Local session ends cleanly.
- `/warphole suck` — pull remote session back. Project files merge, conversation resumes locally.

Anthropic's built-in `/teleport` only pulls web sessions *down* to local. We do the other direction.

The session is the unit of work, not the machine.

---

## 2. Application layer

How you interact with a running workstream from any device.

- **Phone UI** (now) — mobile web app. Open it, see the conversation, send messages, hold to talk. Walkie-talkie mental model: open → in session → talk → done.
- **Mac app** (later) — native menubar/tray. One click to see all active workstreams.
- **iOS app** (later) — native. Better voice, notifications, background refresh.

Currently the phone UI is a local Python server that reads Claude's JSONL directly and controls the tmux session. It starts automatically on the remote VM when you warphole.

---

## 3. Metadata / connector registry

Install once, works everywhere — across agents and machines.

Every agent (Claude Code, Codex, future ones) should share the same skills and tools without manual re-setup. The registry lives at `~/.claude/warphole-registry.json` and syncs to the remote VM on every warphole.

- **Skills** — slash commands (`~/.claude/commands/`). `warphole skills install/list/remove`.
- **MCP servers** — model context protocol tools (`~/.claude/settings.json`). `warphole mcp add/list/remove`.

The insight: agent tooling is currently per-machine and per-agent. It should be a shared layer you configure once.

---

## 4. Observability

An audit trail of what ran where, when, and why.

- Every `warphole go` / `suck` / `list` is logged to `~/.claude/warphole-audit.jsonl`.
- The phone UI Log tab shows this history.
- `warphole log` from the terminal.

The deeper goal: capture the *interplay* between agents. Codex is better on rails (well-scoped tasks, known-good patterns). Claude is better for ambiguity and design. The log should make it visible which agent did what, so you can route work intentionally and see where decisions were made.

Conflict resolution on reclaim (which version of a file wins) is also part of this — currently conservative (preserves local, puts remote in `warphole-incoming/`).

---

## What we're not

- Not a cloud IDE. The agent runs in a real shell on real hardware you control.
- Not an SSH wrapper. The phone server runs co-located with the agent, not as a proxy from your laptop.
- Not Claude-only. The agent adapter pattern (`agents/claude.sh`, `agents/codex.sh`) is the seam for adding new agents without touching core logic.
