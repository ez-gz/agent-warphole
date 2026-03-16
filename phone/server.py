#!/usr/bin/env python3
"""Phone UI server — multi-session remote control for Claude Code.

Exposes ALL Claude sessions on this machine over HTTP. Any browser
(phone, tablet, laptop) can view conversations and send input.

Usage:
    python3 server.py                # scan all sessions, auto-detect tmux
    python3 server.py --port 9000    # custom port

Zero external dependencies. Adapter pattern for multi-agent support.
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import socket
import subprocess
import time
from abc import ABC, abstractmethod
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("phone")

HTML = Path(__file__).with_name("index.html").read_text(encoding="utf-8")

CONVO_TAIL_LINES = 4000
TMUX_CAPTURE_LINES = 400
SESSION_CACHE_TTL = 5.0  # seconds


# ── Shell helpers ────────────────────────────────────────────────────────────

def run(args: list[str], text_input: str | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(args, input=text_input, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise RuntimeError(str(exc)) from exc


def check(result: subprocess.CompletedProcess[str], message: str) -> str:
    if result.returncode == 0:
        return result.stdout
    raise RuntimeError((result.stderr or result.stdout or message).strip())


# ── Tmux ─────────────────────────────────────────────────────────────────────

def tmux_capture(target: str) -> str:
    result = run(["tmux", "capture-pane", "-p", "-t", target, "-S", f"-{TMUX_CAPTURE_LINES}"])
    return check(result, "Cannot capture tmux pane.").rstrip() or "No output captured."


def tmux_send(target: str, text: str, enter: bool, keys: list[str]) -> None:
    if text:
        load = run(["tmux", "load-buffer", "-"], text_input=text)
        check(load, "Cannot stage text for tmux.")
        paste = run(["tmux", "paste-buffer", "-d", "-t", target])
        check(paste, "Cannot paste into tmux session.")

    all_keys = [*keys, "Enter"] if enter else [*keys]
    if all_keys:
        result = run(["tmux", "send-keys", "-t", target, *all_keys])
        check(result, "Cannot send keys to tmux session.")


def scan_tmux_panes() -> list[dict]:
    """Return all tmux panes with metadata."""
    result = run(["tmux", "list-panes", "-a", "-F",
                  "#{session_name}\t#{window_index}\t#{pane_index}\t"
                  "#{pane_current_command}\t#{pane_current_path}"])
    if result.returncode != 0:
        return []
    panes = []
    for line in result.stdout.splitlines():
        parts = line.strip().split("\t")
        if len(parts) < 5:
            continue
        panes.append({
            "session": parts[0],
            "window": parts[1],
            "pane": parts[2],
            "command": parts[3],
            "cwd": parts[4],
            "target": f"{parts[0]}:{parts[1]}.{parts[2]}",
        })
    return panes


def _is_claude_process(command: str) -> bool:
    """Check if a tmux pane command looks like Claude Code."""
    cmd = command.lower()
    if "claude" in cmd:
        return True
    if cmd in ("node", "node.js"):
        return True
    # Version-named binary: e.g. "2.1.76"
    if cmd and cmd[0].isdigit() and "." in cmd:
        return True
    return False


# ── File helpers ─────────────────────────────────────────────────────────────

def _read_file_tail(path: Path, max_lines: int) -> str:
    """Read the last max_lines of a file without loading it all."""
    size = path.stat().st_size
    if size == 0:
        return ""
    if size < 2 * 1024 * 1024:
        return "\n".join(path.read_text(encoding="utf-8").splitlines()[-max_lines:])

    read_size = min(size, max_lines * 1000)
    with open(path, "rb") as f:
        f.seek(max(0, size - read_size))
        if f.tell() > 0:
            f.readline()  # skip partial first line
        tail = f.read().decode("utf-8", errors="replace")
    return "\n".join(tail.split("\n")[-max_lines:])


def _read_file_head(path: Path, max_bytes: int = 4096) -> str:
    """Read the first max_bytes of a file."""
    with open(path, "rb") as f:
        return f.read(max_bytes).decode("utf-8", errors="replace")


def _decode_path(encoded: str) -> str:
    """Reverse the /→- encoding. Leading - becomes /."""
    return encoded.replace("-", "/")


# ── Session Adapter ──────────────────────────────────────────────────────────

class SessionAdapter(ABC):
    """Interface for reading agent conversation logs."""

    name: str = "unknown"

    @abstractmethod
    def scan_sessions(self) -> list[dict]:
        """Discover all sessions on this machine.

        Returns: [{id, uuid, project_path, project_name, encoded_path,
                   jsonl_path, mtime, adapter}]
        """

    @abstractmethod
    def parse_messages(self, raw: str) -> list[dict]:
        """Parse raw conversation file content into structured messages.

        Returns: [{role, text, tools, ts}]
        """

    @abstractmethod
    def extract_meta(self, jsonl_path: Path) -> dict:
        """Extract metadata from a conversation file.

        Returns: {model, branch, last_message, message_count}
        """

    def read_conversation(self, jsonl_path: Path) -> list[dict]:
        """Read and parse a conversation file."""
        if not jsonl_path.exists():
            return []
        tail = _read_file_tail(jsonl_path, CONVO_TAIL_LINES)
        return self.parse_messages(tail)


# ── Claude Adapter ───────────────────────────────────────────────────────────

_XML_BLOCK_RE = re.compile(r"<[\w-]+(?:\s[^>]*)?>[\s\S]*?</[\w-]+>", re.MULTILINE)
_XML_TAG_RE = re.compile(r"<[\w-]+(?:\s[^>]*)?/?>")


class ClaudeAdapter(SessionAdapter):
    """Reads Claude Code conversation JSONL from ~/.claude/projects/."""

    name = "claude"

    def _projects_dir(self) -> Path:
        return Path.home() / ".claude" / "projects"

    def scan_sessions(self) -> list[dict]:
        projects_dir = self._projects_dir()
        if not projects_dir.is_dir():
            return []

        sessions = []
        for encoded_dir in projects_dir.iterdir():
            if not encoded_dir.is_dir():
                continue
            encoded_path = encoded_dir.name
            project_path = _decode_path(encoded_path)
            project_name = project_path.rsplit("/", 1)[-1] if "/" in project_path else project_path

            for jsonl in encoded_dir.glob("*.jsonl"):
                uuid = jsonl.stem
                session_id = f"{encoded_path}__{uuid}"
                try:
                    mtime = jsonl.stat().st_mtime
                except OSError:
                    continue

                sessions.append({
                    "id": session_id,
                    "uuid": uuid,
                    "project_path": project_path,
                    "project_name": project_name,
                    "encoded_path": encoded_path,
                    "jsonl_path": str(jsonl),
                    "mtime": mtime,
                    "adapter": self.name,
                })

        return sessions

    def extract_meta(self, jsonl_path: Path) -> dict:
        meta: dict = {"model": "", "branch": "", "last_message": "", "message_count": 0}
        if not jsonl_path.exists():
            return meta

        # Read head for session metadata (model, branch, cwd)
        head = _read_file_head(jsonl_path)
        for line in head.split("\n")[:10]:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Look for session init record
            if obj.get("type") == "system" or "model" in obj:
                meta["model"] = obj.get("model", "") or obj.get("message", {}).get("model", "")
            if "gitBranch" in obj:
                meta["branch"] = obj["gitBranch"]
            elif isinstance(obj.get("cwd"), str):
                pass  # cwd available but we already have project_path

        # Read tail for last message + count
        tail = _read_file_tail(jsonl_path, 50)
        count = 0
        last_text = ""
        for line in tail.split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            inner = obj.get("message", obj)
            role = inner.get("role") or obj.get("type")
            if role in ("user", "assistant"):
                count += 1
                content = inner.get("content", "")
                if isinstance(content, str):
                    text = _XML_BLOCK_RE.sub("", content)
                    text = _XML_TAG_RE.sub("", text).strip()
                    if text:
                        last_text = text
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            t = block.get("text", "").strip()
                            if t:
                                last_text = t

        meta["last_message"] = last_text[:120]
        meta["message_count"] = count
        return meta

    def _clean_user_text(self, raw: str) -> str:
        text = _XML_BLOCK_RE.sub("", raw)
        text = _XML_TAG_RE.sub("", text)
        return text.strip()

    def parse_messages(self, raw: str) -> list[dict]:
        messages: list[dict] = []

        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get("type")
            inner = obj.get("message", obj)
            role = inner.get("role") or msg_type
            ts = obj.get("timestamp", "")

            if role not in ("user", "assistant"):
                continue

            content = inner.get("content", "")
            text_parts: list[str] = []
            tool_names: list[str] = []

            if isinstance(content, str):
                clean = self._clean_user_text(content)
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

            if not text_parts and not tool_names:
                continue

            messages.append({
                "role": role,
                "text": "\n\n".join(text_parts),
                "tools": tool_names,
                "ts": ts,
            })

        return messages


ADAPTERS: dict[str, SessionAdapter] = {
    "claude": ClaudeAdapter(),
}


# ── Session Discovery ────────────────────────────────────────────────────────

def scan_all_sessions() -> list[dict]:
    """Discover all sessions across all adapters, correlate with tmux."""
    # Gather all sessions from all adapters
    sessions: list[dict] = []
    for adapter in ADAPTERS.values():
        sessions.extend(adapter.scan_sessions())

    # Scan tmux panes for live session matching
    panes = scan_tmux_panes()

    # Index panes by encoded cwd for fast lookup
    panes_by_cwd: dict[str, list[dict]] = {}
    for pane in panes:
        encoded_cwd = pane["cwd"].replace("/", "-")
        panes_by_cwd.setdefault(encoded_cwd, []).append(pane)

    # Match sessions to tmux panes
    for s in sessions:
        s["status"] = "idle"
        s["tmux_target"] = None

        # 1. Check warphole naming: tmux session "warphole-{session_id}"
        warphole_name = f"warphole-{s['id']}"
        for pane in panes:
            if pane["session"] == warphole_name:
                s["status"] = "live"
                s["tmux_target"] = pane["target"]
                break

        if s["status"] == "live":
            continue

        # 2. Match by cwd + Claude process detection
        matching_panes = panes_by_cwd.get(s["encoded_path"], [])
        for pane in matching_panes:
            if _is_claude_process(pane["command"]):
                s["status"] = "live"
                s["tmux_target"] = pane["target"]
                break

    # Extract metadata for each session
    for s in sessions:
        adapter = ADAPTERS.get(s["adapter"])
        if adapter:
            meta = adapter.extract_meta(Path(s["jsonl_path"]))
            s.update(meta)

    # Sort: live first, then by mtime descending
    sessions.sort(key=lambda s: (s["status"] != "live", -s["mtime"]))

    return sessions


# ── Session Cache ────────────────────────────────────────────────────────────

class SessionCache:
    """Simple TTL cache for the session list."""

    def __init__(self, ttl: float = SESSION_CACHE_TTL):
        self._ttl = ttl
        self._data: list[dict] = []
        self._ts: float = 0

    def get(self) -> list[dict]:
        if time.monotonic() - self._ts > self._ttl:
            self._data = scan_all_sessions()
            self._ts = time.monotonic()
        return self._data

    def find(self, session_id: str) -> dict | None:
        for s in self.get():
            if s["id"] == session_id:
                return s
        return None

    def invalidate(self) -> None:
        self._ts = 0


_cache = SessionCache()


# ── HTTP Handler ─────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    server_version = "phone/2.0"

    def _send(self, body: bytes, ct: str, status: HTTPStatus = HTTPStatus.OK) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
        self._send(json.dumps(payload).encode(), "application/json", status)

    def _text(self, text: str, status: HTTPStatus = HTTPStatus.OK) -> None:
        self._send(text.encode(), "text/plain; charset=utf-8", status)

    def _body_json(self) -> dict:
        n = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(n) if n else b"{}")

    def _parse_path(self) -> tuple[str, str | None]:
        """Parse URL path into (route, session_id).

        /api/sessions → ("sessions", None)
        /api/session/SOME_ID/conversation → ("conversation", "SOME_ID")
        """
        path = self.path.split("?")[0]
        parts = path.strip("/").split("/")

        if len(parts) >= 2 and parts[0] == "api":
            if parts[1] == "sessions":
                return "sessions", None
            if parts[1] == "session" and len(parts) >= 4:
                return parts[3], parts[2]
            if parts[1] == "session" and len(parts) == 3:
                return "session_info", parts[2]

        # Top-level routes
        if path == "/":
            return "index", None
        if path == "/health":
            return "health", None

        return "not_found", None

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:
        route, session_id = self._parse_path()

        if route == "index":
            self._send(HTML.encode(), "text/html; charset=utf-8")

        elif route == "health":
            self._text("ok")

        elif route == "sessions":
            sessions = _cache.get()
            # Strip internal fields from response
            clean = []
            for s in sessions:
                clean.append({
                    "id": s["id"],
                    "project_name": s["project_name"],
                    "project_path": s["project_path"],
                    "status": s["status"],
                    "model": s.get("model", ""),
                    "branch": s.get("branch", ""),
                    "mtime": s["mtime"],
                    "last_message": s.get("last_message", ""),
                    "message_count": s.get("message_count", 0),
                    "adapter": s["adapter"],
                })
            self._json({
                "node": socket.gethostname(),
                "sessions": clean,
            })

        elif route == "conversation":
            session = _cache.find(session_id)
            if not session:
                self._json({"messages": [], "error": "Session not found"})
                return
            adapter = ADAPTERS.get(session["adapter"])
            if not adapter:
                self._json({"messages": [], "error": "Unknown adapter"})
                return
            try:
                messages = adapter.read_conversation(Path(session["jsonl_path"]))
                self._json({"messages": messages})
            except Exception as exc:
                log.warning("conversation read failed: %s", exc)
                self._json({"messages": [], "error": str(exc)})

        elif route == "terminal":
            session = _cache.find(session_id)
            if not session:
                self._text("Session not found.", HTTPStatus.NOT_FOUND)
                return
            if not session.get("tmux_target"):
                self._text("Session is not live (no tmux pane).", HTTPStatus.BAD_REQUEST)
                return
            try:
                self._json({"output": tmux_capture(session["tmux_target"])})
            except RuntimeError as exc:
                log.warning("tmux capture failed: %s", exc)
                self._text(str(exc), HTTPStatus.BAD_REQUEST)

        else:
            self._text("Not found", HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        route, session_id = self._parse_path()

        if route != "input":
            self._text("Not found", HTTPStatus.NOT_FOUND)
            return

        session = _cache.find(session_id)
        if not session:
            self._text("Session not found.", HTTPStatus.NOT_FOUND)
            return
        if not session.get("tmux_target"):
            self._text("Session is not live — read-only.", HTTPStatus.BAD_REQUEST)
            return

        payload = self._body_json()
        text = str(payload.get("text", ""))
        enter = bool(payload.get("enter"))
        keys = payload.get("keys", []) or []

        if not isinstance(keys, list) or not all(isinstance(k, str) for k in keys):
            self._text("keys must be an array of strings.", HTTPStatus.BAD_REQUEST)
            return
        if not text and not enter and not keys:
            self._text("Nothing to send.", HTTPStatus.BAD_REQUEST)
            return

        try:
            tmux_send(session["tmux_target"], text=text, enter=enter, keys=keys)
            self._json({"ok": True})
        except RuntimeError as exc:
            log.warning("tmux send failed: %s", exc)
            self._text(str(exc), HTTPStatus.BAD_REQUEST)

    def log_message(self, fmt: str, *args) -> None:
        log.debug(fmt, *args)


# ── Entry point ──────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Phone UI — multi-session remote control")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8420)
    args = parser.parse_args()

    # Initial scan to show what we found
    sessions = _cache.get()
    live = [s for s in sessions if s["status"] == "live"]
    log.info("Found %d sessions (%d live)", len(sessions), len(live))
    for s in sessions[:5]:
        status = "LIVE" if s["status"] == "live" else "idle"
        log.info("  [%s] %s — %s", status, s["project_name"], s["id"][:40])
    if len(sessions) > 5:
        log.info("  ... and %d more", len(sessions) - 5)

    log.info("Node    : %s", socket.gethostname())
    log.info("Serving : http://%s:%d", args.host, args.port)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
