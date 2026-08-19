#!/usr/bin/env python3
"""Installs the Claude Live status hooks into ~/.claude/settings.json.

Idempotent and non-destructive:
  * every entry we add carries a recognisable command path (MARKER), so a
    re-run removes only our own entries before adding them back;
  * hooks belonging to anything else are left exactly as they were, including
    other hooks on the same events;
  * settings.json is backed up before every write and the result is validated
    by re-parsing it.

Usage:
    ./install-claude-hooks.py              install or update
    ./install-claude-hooks.py --uninstall  remove only our hooks
    ./install-claude-hooks.py --dry-run    show what would change
"""

import json
import os
import shutil
import stat
import sys
import time

HOME = os.path.expanduser("~")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
BIN_DIR = os.path.join(HOME, ".claude-hub", "bin")
STATUS_DIR = os.path.join(HOME, ".claude-hub", "status")
HOOK_NAME = "claude-hub-status.py"
HOOK_DEST = os.path.join(BIN_DIR, HOOK_NAME)

# Any hook whose command contains this string is considered ours.
MARKER = HOOK_NAME

# Event → state written by the hook.
#
# Chosen from the documented event list:
#   SessionStart      a session opened; nothing running yet
#   UserPromptSubmit  the user sent a prompt → Claude is working
#   PreToolUse        still working; also refreshes the heartbeat and records
#                     the tool name. Marked async so it never adds latency to a
#                     tool call. PostToolUse is deliberately NOT installed: it
#                     would double the writes without telling us anything new,
#                     since "working" persists until Stop.
#   PermissionRequest Claude needs a permission answer → waiting for input,
#                     and the payload carries the tool name
#   Notification      Claude is asking something / idle-nagging → waiting
#   Stop              the turn finished → idle
#   StopFailure       the turn died on an API error → error
#   SessionEnd        session gone → delete its status file
HOOK_EVENTS = [
    # (event, state, async)
    ("SessionStart", "idle", False),
    ("UserPromptSubmit", "working", False),
    ("PreToolUse", "working", True),
    ("PermissionRequest", "waiting_input", False),
    ("Notification", "waiting_input", False),
    ("Stop", "idle", False),
    ("StopFailure", "error", False),
    ("SessionEnd", "ended", False),
]


def log(message):
    print(message)


def load_settings():
    if not os.path.exists(SETTINGS):
        log(f"· {SETTINGS} non esiste, verrà creato")
        return {}
    with open(SETTINGS, "r") as handle:
        text = handle.read()
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        log(f"✗ {SETTINGS} non è JSON valido ({error}). Nessuna modifica.")
        sys.exit(1)
    if not isinstance(data, dict):
        log(f"✗ {SETTINGS} non contiene un oggetto JSON. Nessuna modifica.")
        sys.exit(1)
    return data


def is_ours(hook_entry):
    if not isinstance(hook_entry, dict):
        return False
    command = hook_entry.get("command")
    return isinstance(command, str) and MARKER in command


def strip_our_hooks(settings):
    """Removes our entries, leaving every other hook untouched. Returns a count."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return 0

    removed = 0
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue

        surviving_groups = []
        for group in groups:
            if not isinstance(group, dict):
                surviving_groups.append(group)
                continue

            inner = group.get("hooks")
            if not isinstance(inner, list):
                surviving_groups.append(group)
                continue

            kept = [h for h in inner if not is_ours(h)]
            removed += len(inner) - len(kept)

            if kept:
                group["hooks"] = kept
                surviving_groups.append(group)
            elif len(inner) == 0:
                # An already-empty group we did not create; leave it alone.
                surviving_groups.append(group)
            # else: the group existed only for our hook → drop it entirely.

        if surviving_groups:
            hooks[event] = surviving_groups
        else:
            del hooks[event]

    if not hooks:
        settings.pop("hooks", None)
    return removed


def hook_timeout(event):
    """How long Claude Code lets our hook run, in seconds.

    Everything but PermissionRequest writes a file and exits, so a few seconds
    is generous. PermissionRequest is different: it *waits* for an answer, and
    the timeout has to be longer than the wait or Claude Code kills the hook
    mid-wait and the answer is lost.

    This used to be 5 for every event, against a default wait of 8 — so an
    answer given between the fifth and the eighth second went nowhere. With the
    iPhone companion the wait can reach a couple of minutes, because a session
    frozen while nobody is at the Mac costs nothing.

    The value is only a ceiling: the hook returns as soon as it has an answer,
    or as soon as `decision_wait_seconds` elapses.
    """
    return 180 if event == "PermissionRequest" else 5


def add_our_hooks(settings):
    hooks = settings.setdefault("hooks", {})

    for event, state, is_async in HOOK_EVENTS:
        entry = {
            "type": "command",
            # Quoted so a home directory containing spaces still works.
            "command": f"'{HOOK_DEST}' {state}",
            "timeout": hook_timeout(event),
        }
        if is_async:
            entry["async"] = True

        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            log(f"✗ hooks.{event} ha un formato inatteso; lo salto.")
            continue

        # Reuse an existing catch-all group when there is one, so we don't
        # accumulate near-duplicate groups next to the user's own hooks.
        catch_all = next(
            (
                g for g in groups
                if isinstance(g, dict)
                and isinstance(g.get("hooks"), list)
                and g.get("matcher", "*") in ("*", "", None)
            ),
            None,
        )
        if catch_all is None:
            groups.append({"hooks": [entry]})
        else:
            catch_all["hooks"].append(entry)


def install_hook_script():
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), HOOK_NAME)
    if not os.path.exists(source):
        log(f"✗ Script hook non trovato accanto all'installer: {source}")
        sys.exit(1)

    os.makedirs(BIN_DIR, exist_ok=True)
    os.makedirs(STATUS_DIR, exist_ok=True)
    shutil.copyfile(source, HOOK_DEST)
    current = os.stat(HOOK_DEST).st_mode
    os.chmod(HOOK_DEST, current | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    log(f"✓ Script hook installato: {HOOK_DEST}")
    log(f"✓ Directory di stato:     {STATUS_DIR}")


def backup(path):
    if not os.path.exists(path):
        return None
    stamp = time.strftime("%Y%m%d-%H%M%S")
    destination = f"{path}.claude-hub-backup-{stamp}"
    shutil.copy2(path, destination)
    return destination


def write_settings(settings):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)

    serialized = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
    # Validate before touching the real file.
    json.loads(serialized)

    saved = backup(SETTINGS)
    if saved:
        log(f"✓ Backup: {saved}")

    tmp = SETTINGS + ".claude-hub-tmp"
    with open(tmp, "w") as handle:
        handle.write(serialized)
    os.replace(tmp, SETTINGS)
    log(f"✓ Aggiornato: {SETTINGS}")


def main():
    uninstall = "--uninstall" in sys.argv
    dry_run = "--dry-run" in sys.argv

    settings = load_settings()
    before = json.dumps(settings, sort_keys=True)

    removed = strip_our_hooks(settings)
    if removed:
        log(f"· Rimosse {removed} voci hook preesistenti di Claude Live")

    if not uninstall:
        add_our_hooks(settings)

    after = json.dumps(settings, sort_keys=True)

    if dry_run:
        log("\n--- dry run: hooks risultanti ---")
        log(json.dumps(settings.get("hooks", {}), indent=2, ensure_ascii=False))
        log("\nNessuna modifica scritta.")
        return

    if not uninstall:
        install_hook_script()

    if before == after:
        log("· settings.json già aggiornato, niente da fare")
    else:
        write_settings(settings)

    if uninstall:
        log("\n✓ Hook di Claude Live rimossi.")
        log(f"  Lo script resta in {HOOK_DEST} (puoi cancellarlo a mano).")
    else:
        events = ", ".join(event for event, _, _ in HOOK_EVENTS)
        log(f"\n✓ Hook installati su: {events}")
        log("  Riavvia le sessioni Claude Code aperte perché li carichino.")


if __name__ == "__main__":
    main()
