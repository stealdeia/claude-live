"""Exercises the gate end to end, against a throwaway hub.

The module's paths are rebound after import so nothing here can touch
~/.claude-hub: writing `away: true` into the real config would make every live
session start holding its tool calls, including another person's.
"""
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time
from io import StringIO

HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources", "claude-hub-status.py")

spec = importlib.util.spec_from_file_location("hook", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

HUB = tempfile.mkdtemp(prefix="hub-test-")
hook.HUB = HUB
hook.STATUS_DIR = os.path.join(HUB, "status")
hook.DECISIONS_DIR = os.path.join(HUB, "decisions")
hook.ALLOWLIST = os.path.join(HUB, "allowlist.json")
hook.HEARTBEAT = os.path.join(HUB, "app-heartbeat")
hook.CONFIG = os.path.join(HUB, "config.json")
os.makedirs(hook.STATUS_DIR, exist_ok=True)
os.makedirs(hook.DECISIONS_DIR, exist_ok=True)

# A live app: our own pid, so the process check passes.
with open(hook.HEARTBEAT, "w") as f:
    json.dump({"pid": os.getpid(), "at": time.time()}, f)

failures = []


def check(label, got, want):
    ok = got == want
    print(f"{'  ok  ' if ok else ' FAIL '} {label}: {got!r}")
    if not ok:
        failures.append(f"{label}: atteso {want!r}, ottenuto {got!r}")


def configure(**kwargs):
    with open(hook.CONFIG, "w") as f:
        json.dump(kwargs, f)


def run(payload, state="working"):
    """Runs main() with a payload, returning what it printed."""
    sys.argv = ["hook", state]
    sys.stdin = StringIO(json.dumps(payload))
    out = StringIO()
    real, sys.stdout = sys.stdout, out
    try:
        hook.main()
    finally:
        sys.stdout = real
    return out.getvalue()


BASH = {
    "hook_event_name": "PreToolUse",
    "session_id": "s1",
    "cwd": "/tmp/progetto",
    "tool_name": "Bash",
    "tool_use_id": "toolu_abc",
    "tool_input": {"command": "rm -rf build"},
}

print("\n— quando NON si deve fermare —")

configure(away=False, decision_wait_seconds=60)
check("a casa, non blocca", run(BASH), "")

configure(away=True, decision_wait_seconds=60)
read_only = dict(BASH, tool_name="Read", tool_use_id="toolu_r", tool_input={"file_path": "/tmp/x"})
check("via, ma strumento di sola lettura", run(read_only), "")

configure(away=True, decision_wait_seconds=0)
check("via, ma attesa a zero", run(BASH), "")

print("\n— quando si deve fermare —")

configure(away=True, decision_wait_seconds=8)


def answer_after(delay, request_id, behavior):
    def go():
        time.sleep(delay)
        with open(os.path.join(hook.DECISIONS_DIR, f"{request_id}.json"), "w") as f:
            json.dump({"behavior": behavior, "remember": False}, f)
    threading.Thread(target=go, daemon=True).start()


answer_after(0.5, "toolu_abc", "allow")
started = time.time()
output = run(BASH)
waited = time.time() - started

decision = json.loads(output) if output else {}
check(
    "consenti dal telefono",
    decision.get("hookSpecificOutput", {}).get("permissionDecision"),
    "allow",
)
check(
    "forma dell'evento",
    decision.get("hookSpecificOutput", {}).get("hookEventName"),
    "PreToolUse",
)
print(f"       ha davvero atteso: {waited:.1f}s")

answer_after(0.5, "toolu_deny", "deny")
denied = run(dict(BASH, tool_use_id="toolu_deny"))
check(
    "nega dal telefono",
    json.loads(denied).get("hookSpecificOutput", {}).get("permissionDecision"),
    "deny",
)

print("\n— scadenza senza risposta —")
configure(away=True, decision_wait_seconds=1)
started = time.time()
timed_out = run(dict(BASH, tool_use_id="toolu_silence"))
# Nothing printed: Claude Code then asks in the terminal exactly as it would
# without this hook. Denying instead would stop work nobody objected to.
check("nessuno risponde → nessuna decisione", timed_out, "")
print(f"       ha atteso e mollato dopo: {time.time() - started:.1f}s")

print("\n— torni al Mac mentre la richiesta è in sospeso —")
configure(away=True, decision_wait_seconds=60)


def come_back_after(delay):
    def go():
        time.sleep(delay)
        configure(away=False, decision_wait_seconds=60)
    threading.Thread(target=go, daemon=True).start()


come_back_after(0.5)
started = time.time()
returned = run(dict(BASH, tool_use_id="toolu_back"))
elapsed = time.time() - started
# Lets go at once instead of holding for the full minute: the person who can
# answer is now sitting in front of the terminal, which is the whole reason the
# away/home distinction exists.
check("smette di aspettare", returned, "")
check("senza arrivare in fondo ai 60s", elapsed < 5, True)
print(f"       ha mollato dopo: {elapsed:.1f}s")

print("\n— cosa vede il pannello mentre aspetta —")
configure(away=True, decision_wait_seconds=1)
run(dict(BASH, tool_use_id="toolu_look"))
status_file = [f for f in os.listdir(hook.STATUS_DIR) if f.endswith(".json")][0]
record = json.load(open(os.path.join(hook.STATUS_DIR, status_file)))
# Still waiting after the hook gives up, and rightly: Claude Code then shows its
# own prompt and the session really is waiting on a person. What changes is
# `decidable` — "no longer answerable from here" — so the panel stops offering
# buttons that would go nowhere.
check("stato dopo la scadenza", record["state"], "waiting_input")
check("non più rispondibile da remoto", record["decidable"], False)
check("badge", record["request_kind"], "permission")
print(f"       tool={record['tool_name']!r} summary={record['tool_summary']!r}")

print()
if failures:
    print(f"✗ {len(failures)} verifiche fallite")
    for f in failures:
        print("   ", f)
    sys.exit(1)
print("✓ tutte le verifiche passate")
