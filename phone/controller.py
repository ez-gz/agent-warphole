#!/usr/bin/env python3
"""Phone UI server for a local Claude Code session.

Reads the conversation JSONL directly from ~/.claude/projects/ and
controls the Claude process via a local tmux session.

Usage:
  ./phone_ui.sh --session <tmux-session-name>
  ./phone_ui.sh --session <name> --project /path/to/project

The server is intentionally local-only. For remote (warphole) use,
deploy it on the VM alongside Claude — not as an SSH proxy.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HTML = Path(__file__).with_name("index.html").read_text(encoding="utf-8")

LOG_LINES = 300
CONVO_LINES = 4000


# ── Shell helpers ─────────────────────────────────────────────────────────────

def run(args: list[str], text_input: str | None = None) -> subprocess.CompletedProcess[str]:
  try:
    return subprocess.run(args, input=text_input, capture_output=True, text=True, check=False)
  except OSError as exc:
    raise RuntimeError(str(exc)) from exc


def check(result: subprocess.CompletedProcess[str], message: str) -> str:
  if result.returncode == 0:
    return result.stdout
  raise RuntimeError((result.stderr or result.stdout or message).strip())


# ── Tmux ──────────────────────────────────────────────────────────────────────

def tmux_session_exists(session: str) -> bool:
  return run(["tmux", "has-session", "-t", session]).returncode == 0


def tmux_cwd(session: str) -> str:
  result = run(["tmux", "display-message", "-p", "-t", session, "#{pane_current_path}"])
  return check(result, f"Cannot read cwd from tmux session: {session}").strip()


def tmux_capture(session: str) -> str:
  result = run(["tmux", "capture-pane", "-p", "-t", session, "-S", f"-{LOG_LINES}"])
  return check(result, "Cannot capture tmux pane.").rstrip() or "No output captured."


def tmux_send(session: str, text: str, enter: bool, keys: list[str]) -> None:
  if text:
    load = run(["tmux", "load-buffer", "-"], text_input=text)
    check(load, "Cannot stage text for tmux.")
    paste = run(["tmux", "paste-buffer", "-d", "-t", session])
    check(paste, "Cannot paste into tmux session.")

  all_keys = [*keys, "Enter"] if enter else [*keys]
  if all_keys:
    result = run(["tmux", "send-keys", "-t", session, *all_keys])
    check(result, "Cannot send keys to tmux session.")


# ── Conversation JSONL ────────────────────────────────────────────────────────

def project_dir(project_path: str) -> Path:
  """~/.claude/projects/{path-with-slashes-as-dashes}"""
  encoded = project_path.replace("/", "-")
  return Path.home() / ".claude" / "projects" / encoded


def latest_jsonl(project_path: str) -> Path:
  d = project_dir(project_path)
  files = sorted(d.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
  if not files:
    raise RuntimeError(f"No conversation file found in {d}")
  return files[0]


# Matches XML-style blocks Claude Code prepends to user message strings
# e.g. <system-reminder>...</system-reminder>, <local-command-caveat>...</local-command-caveat>
_XML_BLOCK_RE = re.compile(r"<[\w-]+(?:\s[^>]*)?>[\s\S]*?</[\w-]+>", re.MULTILINE)
_XML_TAG_RE   = re.compile(r"<[\w-]+(?:\s[^>]*)?/?>")


def _clean_user_text(raw: str) -> str:
  """Strip Claude Code metadata tags, leaving only the human-typed text."""
  text = _XML_BLOCK_RE.sub("", raw)
  text = _XML_TAG_RE.sub("", text)
  return text.strip()


def parse_messages(raw: str) -> list[dict]:
  """Parse Claude Code JSONL into a clean list of {role, text, tools} dicts.

  Handles the {type, message, uuid, timestamp} envelope Claude Code writes.
  User message strings have XML metadata stripped; assistant list content is
  split into text and tool names. Skips tool_result turns and system records.
  """
  messages: list[dict] = []

  for line in raw.splitlines():
    line = line.strip()
    if not line:
      continue
    try:
      obj = json.loads(line)
    except json.JSONDecodeError:
      continue

    # Unwrap envelope
    msg_type = obj.get("type")                   # "user" | "assistant" | "tool" | …
    inner    = obj.get("message", obj)           # the actual {role, content} object
    role     = inner.get("role") or msg_type

    if role not in ("user", "assistant"):
      continue                                   # skip system, tool_result, summary, etc.

    content    = inner.get("content", "")
    text_parts: list[str] = []
    tool_names: list[str] = []

    if isinstance(content, str):
      # User messages are bare strings with XML metadata prepended by Claude Code.
      clean = _clean_user_text(content)
      if clean:
        text_parts.append(clean)

    elif isinstance(content, list):
      for block in content:
        if not isinstance(block, dict):
          continue
        btype = block.get("type")
        if btype == "text":
          t = block.get("text", "").strip()
          if t:
            text_parts.append(t)
        elif btype == "tool_use":
          tool_names.append(block.get("name", "tool"))
        # tool_result: skip

    if not text_parts and not tool_names:
      continue

    messages.append({
      "role":  role,
      "text":  "\n\n".join(text_parts),
      "tools": tool_names,
    })

  return messages


def read_conversation(project_path: str) -> list[dict]:
  jsonl = latest_jsonl(project_path)
  raw   = jsonl.read_text(encoding="utf-8")
  tail  = "\n".join(raw.splitlines()[-CONVO_LINES:])
  return parse_messages(tail)


# ── HTTP handler ──────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
  server_version = "warphole-phone/0.2"

  @property
  def _session(self) -> str:
    return self.server.session  # type: ignore[attr-defined]

  @property
  def _project(self) -> str:
    return self.server.project_path  # type: ignore[attr-defined]

  def _send(self, body: bytes, ct: str, status: HTTPStatus = HTTPStatus.OK) -> None:
    self.send_response(status)
    self.send_header("Content-Type", ct)
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def _json(self, payload: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
    self._send(json.dumps(payload).encode(), "application/json", status)

  def _text(self, text: str, status: HTTPStatus = HTTPStatus.OK) -> None:
    self._send(text.encode(), "text/plain; charset=utf-8", status)

  def _body_json(self) -> dict:
    n = int(self.headers.get("Content-Length", "0"))
    return json.loads(self.rfile.read(n) if n else b"{}")

  def do_GET(self) -> None:
    path = self.path.split("?")[0]

    if path == "/":
      self._send(HTML.encode(), "text/html; charset=utf-8")

    elif path == "/health":
      self._text("ok")

    elif path == "/api/info":
      self._json({
        "project": self._project,
        "session": self._session,
        "has_session": bool(self._session),
      })

    elif path == "/api/conversation":
      if not self._project:
        self._json({"messages": []})
        return
      try:
        messages = read_conversation(self._project)
        self._json({"messages": messages})
      except RuntimeError as exc:
        self._text(str(exc), HTTPStatus.BAD_REQUEST)

    elif path == "/api/log":
      if not self._session:
        self._text("No tmux session configured.", HTTPStatus.BAD_REQUEST)
        return
      try:
        self._json({"log": tmux_capture(self._session)})
      except RuntimeError as exc:
        self._text(str(exc), HTTPStatus.BAD_REQUEST)

    elif path == "/api/audit":
      audit_log = Path.home() / ".claude" / "warphole-audit.jsonl"
      try:
        if not audit_log.exists():
          self._json({"entries": []})
          return
        raw = audit_log.read_text(encoding="utf-8")
        entries: list[dict] = []
        for line in raw.splitlines()[-100:]:
          line = line.strip()
          if not line:
            continue
          try:
            entries.append(json.loads(line))
          except json.JSONDecodeError:
            continue
        self._json({"entries": entries})
      except Exception as exc:
        self._text(str(exc), HTTPStatus.BAD_REQUEST)

    else:
      self._text("Not found", HTTPStatus.NOT_FOUND)

  def do_POST(self) -> None:
    path = self.path.split("?")[0]

    if path != "/api/input":
      self._text("Not found", HTTPStatus.NOT_FOUND)
      return

    if not self._session:
      self._text("No tmux session configured — server is read-only.", HTTPStatus.BAD_REQUEST)
      return

    payload = self._body_json()
    text    = str(payload.get("text", ""))
    enter   = bool(payload.get("enter"))
    keys    = payload.get("keys", []) or []

    if not isinstance(keys, list) or not all(isinstance(k, str) for k in keys):
      self._text("keys must be an array of strings.", HTTPStatus.BAD_REQUEST)
      return
    if not text and not enter and not keys:
      self._text("Nothing to send.", HTTPStatus.BAD_REQUEST)
      return

    try:
      tmux_send(self._session, text=text, enter=enter, keys=keys)
      self._json({"ok": True})
    except RuntimeError as exc:
      self._text(str(exc), HTTPStatus.BAD_REQUEST)

  def log_message(self, _fmt: str, *_args) -> None:
    return


# ── Entry point ───────────────────────────────────────────────────────────────

def auto_detect_session() -> str | None:
  """Find the first local tmux pane running Claude Code. Returns None if tmux unavailable.

  Claude Code runs as a Node.js process. The pane command seen by tmux varies:
  'claude' (native binary wrapper), 'node', or a version string like '2.1.76'.
  Strategy: prefer an explicit 'claude' match; fall back to any pane whose
  current path has a matching ~/.claude/projects/ directory.
  """
  try:
    result = run(["tmux", "list-panes", "-a", "-F",
                  "#{session_name}\t#{pane_current_command}\t#{pane_current_path}"])
  except RuntimeError:
    return None
  if result.returncode != 0:
    return None

  claude_projects = Path.home() / ".claude" / "projects"
  candidates: list[str] = []

  for line in result.stdout.splitlines():
    parts = line.strip().split("\t", 2)
    if len(parts) < 2:
      continue
    session_name = parts[0]
    cmd          = parts[1].lower()
    pane_path    = parts[2] if len(parts) > 2 else ""

    # Strong match: process name contains 'claude'
    if "claude" in cmd:
      return session_name

    # Weak match: node/versioned process in a dir that has a .claude projects entry
    if cmd in ("node", "node.js") or cmd[0].isdigit():
      if pane_path:
        encoded = pane_path.replace("/", "-")
        if (claude_projects / encoded).is_dir():
          candidates.append(session_name)

  return candidates[0] if candidates else None


def main() -> None:
  parser = argparse.ArgumentParser(description="Warphole phone UI — local Claude Code session")
  parser.add_argument("--host",    default="0.0.0.0")
  parser.add_argument("--port",    type=int, default=8420)
  parser.add_argument("--session", default=None,
                      help="tmux session name running Claude Code (auto-detected if omitted)")
  parser.add_argument("--project", default=None,
                      help="Project directory (defaults to the tmux session's cwd or cwd)")
  args = parser.parse_args()

  session = args.session or auto_detect_session()

  if session and not tmux_session_exists(session):
    parser.error(f"tmux session not found: {session}")

  # Resolve project path — empty string means "waiting mode" (no session yet)
  if args.project:
    project_path = str(Path(args.project).resolve())
  elif session:
    try:
      project_path = tmux_cwd(session)
    except RuntimeError:
      project_path = ""
  else:
    project_path = ""

  # Try to find the conversation file, but don't hard-fail — server starts in
  # waiting mode if no project is available yet (e.g. boot before warphole go).
  jsonl = None
  if project_path:
    try:
      jsonl = latest_jsonl(project_path)
    except RuntimeError as exc:
      print(f"Warning: {exc} — starting in waiting mode")

  print(f"Project : {project_path or '(waiting for session)'}")
  print(f"Session : {session or '(none — read-only)'}")
  if jsonl:
    print(f"JSONL   : {jsonl}")
  print(f"Serving : http://{args.host}:{args.port}")

  server = ThreadingHTTPServer((args.host, args.port), Handler)
  server.session      = session or ""  # type: ignore[attr-defined]
  server.project_path = project_path   # type: ignore[attr-defined]
  server.serve_forever()


if __name__ == "__main__":
  main()
