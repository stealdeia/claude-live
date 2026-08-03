#!/usr/bin/env python3
"""Claude Code hook: reports session state to Claude Live, and — for permission
requests — lets Claude Live answer on the user's behalf.

Invoked by the hooks installed in ~/.claude/settings.json as:

    claude-hub-status.py <state>

where <state> is one of: working | idle | waiting_input | error | ended.
The hook payload arrives as JSON on stdin.

## Files

    ~/.claude-hub/status/<project-hash>.<session>.json   session state
    ~/.claude-hub/decisions/<request-id>.json            written by the app
    ~/.claude-hub/allowlist.json                         remembered "always allow"
    ~/.claude-hub/app-heartbeat                          touched by the running app
    ~/.claude-hub/config.json                            { "decision_wait_seconds": N }

One status file per *session* rather than per project: two Claude Code sessions
can run in the same project, and per-session files mean each process only writes
its own — no read-modify-write races. Claude Live groups them by project_path.

## Answering permissions from the panel

`PermissionRequest` hooks may decide the outcome by printing
`hookSpecificOutput.decision.behavior` = allow | deny. The hook is *blocking*, so
while it waits Claude Code shows no prompt of its own; printing nothing lets the
normal terminal prompt appear as usual.

Waiting therefore only happens when it can plausibly pay off:
  * the app is running (fresh heartbeat), and
  * a wait is configured (`decision_wait_seconds` > 0).
Otherwise the hook returns immediately and nothing changes for the terminal.

Never fails loudly: a broken status hook must not disrupt a Claude Code session,
so every error path exits 0 without a decision.
"""

import hashlib
import json
import os
import sys
import tempfile
import time

HUB = os.path.join(os.path.expanduser("~"), ".claude-hub")
STATUS_DIR = os.path.join(HUB, "status")
DECISIONS_DIR = os.path.join(HUB, "decisions")
ALLOWLIST = os.path.join(HUB, "allowlist.json")
HEARTBEAT = os.path.join(HUB, "app-heartbeat")
CONFIG = os.path.join(HUB, "config.json")

SCHEMA = 2
# A heartbeat older than this is ignored even if the pid happens to exist,
# which guards against a recycled pid from an earlier run.
HEARTBEAT_MAX_AGE = 60
DEFAULT_WAIT_SECONDS = 0
POLL_INTERVAL = 0.15


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


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default


def repository_root(start):
    """Nearest ancestor that is a git repository, or `start` if there is none.

    `claude` is often launched from a subdirectory, and reporting that
    subdirectory would show up as a separate project. The home directory and the
    filesystem root are never candidates: `~/.git` or `~/.claude` exist on plenty
    of machines and would swallow every project. Non-git projects are left as-is
    here — Claude Live folds them onto the right project using VS Code's own
    workspace list, which this script cannot see.
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


def short(text, limit=140):
    return " ".join(str(text).split())[:limit]


def tool_summary(payload):
    """One readable line describing what Claude wants to do.

    Shown on a panel button, so the interesting part of the tool input matters
    more than completeness: the command for Bash, the path for file edits.
    """
    tool = payload.get("tool_name") or ""
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return short(tool)

    for key in ("command", "file_path", "path", "pattern", "url", "prompt"):
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return short(value)

    try:
        return short(json.dumps(data, ensure_ascii=False))
    except Exception:
        return short(tool)


def detail(payload):
    """Short human-readable extra: the tool name, the message, the error type."""
    for key in ("tool_name", "message", "error_type", "error_message"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return short(value, 120)
    return None


def write_atomic(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(obj, handle)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# --- Permission decisions ----------------------------------------------------


def app_is_running():
    """True only if Claude Live is really there to answer.

    Freshness alone is not enough: a force-quit or a crash never runs the app's
    cleanup, so the file survives and every permission request would stall for the
    full wait with nobody listening. The file therefore carries the pid, and this
    checks the process exists. Freshness is still required, to rule out a recycled
    pid from a much earlier run.
    """
    try:
        with open(HEARTBEAT, encoding="utf-8") as handle:
            beat = json.load(handle)
        if time.time() - float(beat.get("at", 0)) > HEARTBEAT_MAX_AGE:
            return False
        pid = int(beat.get("pid", 0))
    except Exception:
        return False

    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Exists, owned by someone else; good enough.
        return True
    except Exception:
        return False
    return True


def wait_seconds():
    config = read_json(CONFIG, {})
    try:
        return max(0, min(120, float(config.get("decision_wait_seconds", DEFAULT_WAIT_SECONDS))))
    except Exception:
        return DEFAULT_WAIT_SECONDS


def request_fingerprint(path, tool, payload):
    """Identifies "this exact request in this project", for the allowlist.

    Deliberately includes the full tool input: remembering "always allow Bash in
    this project" would be far broader than what the user agreed to. Two requests
    only match if the command is byte-for-byte the same.
    """
    try:
        blob = json.dumps(payload.get("tool_input"), sort_keys=True, ensure_ascii=False)
    except Exception:
        blob = ""
    raw = "\x00".join([path, tool, blob])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def allowlisted(fingerprint):
    entries = read_json(ALLOWLIST, [])
    if not isinstance(entries, list):
        return False
    return any(isinstance(e, dict) and e.get("fingerprint") == fingerprint for e in entries)


def remember(fingerprint, path, tool, summary):
    entries = read_json(ALLOWLIST, [])
    if not isinstance(entries, list):
        entries = []
    if any(isinstance(e, dict) and e.get("fingerprint") == fingerprint for e in entries):
        return
    entries.append({
        "fingerprint": fingerprint,
        "project_path": path,
        "tool_name": tool,
        "summary": summary,
        "added_at": time.time(),
    })
    write_atomic(ALLOWLIST, entries)


def emit_decision(behavior):
    """Prints the decision in the shape Claude Code expects for PermissionRequest."""
    json.dump({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": behavior},
        }
    }, sys.stdout)
    sys.stdout.flush()


def await_decision(request_id, timeout):
    """Polls for the app's answer. Returns (behavior, remember) or None."""
    path = os.path.join(DECISIONS_DIR, f"{request_id}.json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            answer = read_json(path, {})
            try:
                os.remove(path)
            except OSError:
                pass
            behavior = answer.get("behavior")
            if behavior in ("allow", "deny"):
                return behavior, bool(answer.get("remember"))
            return None
        time.sleep(POLL_INTERVAL)
    return None


# --- Main --------------------------------------------------------------------


def main():
    state = sys.argv[1] if len(sys.argv) > 1 else "idle"
    payload = read_payload()

    path = project_path(payload)
    if not path:
        # No project to attribute this to (empty or unreadable payload).
        return

    session = payload.get("session_id") or "unknown"
    digest = hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]
    safe_session = "".join(c for c in str(session) if c.isalnum() or c in "-_")[:40]
    target = os.path.join(STATUS_DIR, f"{digest}.{safe_session}.json")

    if state == "ended":
        try:
            os.remove(target)
        except OSError:
            pass
        return

    event = payload.get("hook_event_name") or ""
    is_permission = event == "PermissionRequest"
    tool = payload.get("tool_name") or ""
    summary = tool_summary(payload) if is_permission else None
    request_id = payload.get("tool_use_id") or ""
    fingerprint = request_fingerprint(path, tool, payload) if is_permission else None

    # An identical request the user already chose to always allow: answer at once
    # and leave the session marked as working rather than waiting.
    if is_permission and fingerprint and allowlisted(fingerprint):
        emit_decision("allow")
        state = "working"
        is_permission = False

    timeout = wait_seconds() if is_permission else 0
    decidable = bool(is_permission and request_id and timeout > 0 and app_is_running())

    record = {
        "schema": SCHEMA,
        "state": state,
        "project_path": path,
        "project_name": os.path.basename(path.rstrip("/")) if path else "",
        "cwd": payload.get("cwd") or "",
        "session_id": session,
        "event": event,
        "permission_mode": payload.get("permission_mode"),
        "request_kind": request_kind(payload, state),
        "detail": detail(payload),
        # Fields below drive the panel's inline answer buttons.
        "request_id": request_id,
        "tool_name": tool,
        "tool_summary": summary,
        "decidable": decidable,
        "updated_at_epoch": time.time(),
        "pid": os.getpid(),
    }
    write_atomic(target, record)

    if not decidable:
        return

    answer = await_decision(request_id, timeout)
    if answer is None:
        # No answer in time: print nothing, so Claude Code prompts in the terminal
        # exactly as it would without this hook.
        record["decidable"] = False
        record["updated_at_epoch"] = time.time()
        write_atomic(target, record)
        return

    behavior, should_remember = answer
    if behavior == "allow" and should_remember and fingerprint:
        remember(fingerprint, path, tool, summary or tool)

    emit_decision(behavior)

    # The answer was given, so the session is no longer waiting on the user.
    record["state"] = "working" if behavior == "allow" else "idle"
    record["decidable"] = False
    record["request_id"] = ""
    record["updated_at_epoch"] = time.time()
    write_atomic(target, record)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # A status hook must never break the session it is observing.
        pass
    sys.exit(0)
