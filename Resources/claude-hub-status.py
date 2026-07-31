#!/usr/bin/env python3
"""Claude Code hook: records the session's activity state for Claude Live.

Invoked by the hooks installed in ~/.claude/settings.json as:

    claude-hub-status.py <state>

where <state> is one of: working | idle | waiting_input | error | ended.
The hook payload arrives as JSON on stdin.

Writes ~/.claude-hub/status/<project-hash>.<session-id>.json

One file per *session* rather than per project: two Claude Code sessions can run
in the same project (say an integrated terminal plus a standalone one), and
per-session files mean each process only ever writes its own file — no
read-modify-write races. Claude Live groups them back together by project_path
and shows the most urgent state.

Never fails loudly: a broken status hook must not disrupt a Claude Code session,
so every error path exits 0.
"""

import hashlib
import json
import os
import sys
import tempfile
import time

STATUS_DIR = os.path.join(os.path.expanduser("~"), ".claude-hub", "status")
SCHEMA = 1


def read_payload():
    try:
        raw = sys.stdin.read()
    except Exception:
        return {}
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def repository_root(start):
    """Nearest ancestor that is a git repository, or `start` if there is none.

    `claude` is often launched from a subdirectory, and reporting that
    subdirectory would show up as a separate project. Walking up to the git root
    groups those sessions under one project.

    The home directory and the filesystem root are never candidates: `~/.git`
    or `~/.claude` exist on plenty of machines and would swallow every project.
    Non-git projects are left as-is here — Claude Live folds them onto the right
    project using VS Code's own workspace list, which this script cannot see.
    """
    home = os.path.realpath(os.path.expanduser("~"))
    current = os.path.realpath(start)

    while True:
        parent = os.path.dirname(current)
        if current in (home, parent):
            return start
        if os.path.exists(os.path.join(current, ".git")):
            return current
        current = parent


def project_path(payload):
    """CLAUDE_PROJECT_DIR is the project root; cwd may be a subdirectory of it."""
    explicit = os.environ.get("CLAUDE_PROJECT_DIR")
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))

    cwd = payload.get("cwd")
    if cwd:
        return repository_root(os.path.abspath(os.path.expanduser(cwd)))

    return ""


def request_kind(payload, state):
    """What kind of answer Claude is waiting for, when it is waiting."""
    event = payload.get("hook_event_name") or ""
    if event == "PermissionRequest":
        return "permission"
    if event == "Notification":
        return payload.get("notification_type") or "notification"
    if state == "waiting_input":
        return "input"
    return None


def detail(payload):
    """Short human-readable extra: the tool name, the message, the error type."""
    for key in ("tool_name", "message", "error_type", "error_message"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            # Keep it short: this ends up in a cramped panel row.
            text = " ".join(value.split())
            return text[:120]
    return None


def main():
    state = sys.argv[1] if len(sys.argv) > 1 else "idle"
    payload = read_payload()

    path = project_path(payload)
    if not path:
        # No project to attribute this to (empty or unreadable payload):
        # writing a record keyed on "" would just litter the directory.
        return

    session = payload.get("session_id") or "unknown"

    # Same hashing on both sides is not required — Claude Live reads
    # project_path from the file contents — but a stable, greppable name makes
    # the directory easy to inspect by hand.
    digest = hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]
    safe_session = "".join(c for c in str(session) if c.isalnum() or c in "-_")[:40]
    target = os.path.join(STATUS_DIR, f"{digest}.{safe_session}.json")

    if state == "ended":
        try:
            os.remove(target)
        except OSError:
            pass
        return

    record = {
        "schema": SCHEMA,
        "state": state,
        "project_path": path,
        "project_name": os.path.basename(path.rstrip("/")) if path else "",
        "cwd": payload.get("cwd") or "",
        "session_id": session,
        "event": payload.get("hook_event_name") or "",
        "permission_mode": payload.get("permission_mode"),
        "request_kind": request_kind(payload, state),
        "detail": detail(payload),
        "updated_at_epoch": time.time(),
        "pid": os.getpid(),
    }

    os.makedirs(STATUS_DIR, exist_ok=True)

    # Atomic replace, so Claude Live never reads a half-written file.
    fd, tmp = tempfile.mkstemp(dir=STATUS_DIR, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(record, handle)
        os.replace(tmp, target)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # A status hook must never break the session it is observing.
        pass
    sys.exit(0)
