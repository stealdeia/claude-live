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
# Una richiesta rispondibile per file, in una cartella sua.
#
# Il file di stato della sessione è uno solo e lo riscrive qualunque
# evento: `Notification` e `PermissionRequest` arrivano nello stesso
# istante descrivendo la stessa domanda in una forma a cui nessuno può
# rispondere, e vince l'ultimo che scrive. Difenderlo è stato rattoppato
# due volte il 2026-08-21 e ha continuato a perdere: la richiesta che
# l'hook sta aspettando non deve condividere un file con nient'altro.
PENDING_DIR = os.path.join(HUB, "pending")
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
    # A held PreToolUse is a permission question too, whatever the event is
    # called — and the panel's badge should say so rather than "input".
    if event == "PreToolUse" and state == "waiting_input":
        return "permission"
    if event == "Notification":
        return payload.get("notification_type") or "notification"
    if state == "waiting_input":
        return "input"
    return None


def short(text, limit=140):
    return " ".join(str(text).split())[:limit]


# Keys whose value says what a request is about, most telling first. The order
# carries the judgement: for Bash the command beats any description of it, for an
# edit the path beats the text being written.
TELLING_KEYS = (
    "command", "file_path", "path", "pattern", "url", "prompt",
    "question", "description", "query", "content",
)


def telling_string(data, depth=0):
    """The most descriptive string inside a tool input, however nested.

    Nested on purpose: a tool input is not always flat. `AskUserQuestion` keeps
    its text at `questions[0]["question"]`, where a flat lookup finds nothing.
    """
    if depth > 4:
        return None
    if isinstance(data, dict):
        for key in TELLING_KEYS:
            value = data.get(key)
            if isinstance(value, str) and value.strip():
                return value
        for value in data.values():
            found = telling_string(value, depth + 1)
            if found:
                return found
    elif isinstance(data, list):
        for value in data:
            found = telling_string(value, depth + 1)
            if found:
                return found
    return None


def tool_summary(payload):
    """One readable line describing what Claude wants to do.

    Shown on a panel button and inside a macOS notification, so the interesting
    part of the tool input matters more than completeness: the command for Bash,
    the path for file edits.

    Never falls back to dumping the input as JSON. It used to, and on 2026-08-20
    a permission notification arrived as a wall of braces and quotes — the tool
    was `AskUserQuestion`, whose text is nested and so matched none of the keys
    being looked at. A tool's bare name says less, but a notification nobody can
    read says nothing at all.
    """
    tool = payload.get("tool_name") or ""
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return short(tool)

    found = telling_string(data)
    return short(found) if found else short(tool)


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


def wait_seconds(reason="away"):
    """Quanto attendere una risposta, secondo il motivo per cui si trattiene.

    Da lontano l'attesa può essere lunga: la sessione sarebbe rimasta ferma
    comunque, e serve il tempo di accorgersi della notifica, sbloccare il
    telefono e leggere. Con la finestra coperta l'utente è qui, e il terminale
    tace finché si aspetta: pochi secondi, quanto basta a vedere il pannello.
    """
    config = read_json(CONFIG, {})
    key = "covered_wait_seconds" if reason == "covered" else "decision_wait_seconds"
    default = 45 if reason == "covered" else DEFAULT_WAIT_SECONDS
    try:
        return max(0, min(600, float(config.get(key, default))))
    except Exception:
        return default


# Tools that can change something. Read-only ones are never worth interrupting
# for: they cannot do damage, and asking about them would turn one task into
# twenty questions.
DEFAULT_GATED_TOOLS = ["Bash", "Write", "Edit", "NotebookEdit"]


# The only modes in which Claude Code stops to ask. Anything else — the
# automatic ones, plan mode, whatever gets added next — decides by itself, so
# there is no question to intercept.
#
# An unrecognised mode is treated as one that does not ask, and the absence of
# the field as one that does. The asymmetry is deliberate: holding a call nobody
# would have been asked about freezes the session for minutes, while letting one
# through only means the question appears in the terminal instead of on the phone.
# A build new enough to name a mode we have never heard of is far more likely to
# have added a permissive one; a build too old to send the field at all needs the
# old behaviour or the feature disappears.
ASKING_MODES = ("default", "acceptEdits")


def permission_rules(path, kind):
    """The `allow`, `ask` or `deny` rules that apply here.

    Read fresh every time rather than cached: a rule the user adds mid-session
    takes effect for Claude Code at once, and a stale copy here would keep
    holding a call that has stopped asking anything.
    """
    rules = []
    for candidate in (
        os.path.join(os.path.expanduser("~"), ".claude", "settings.json"),
        os.path.join(path, ".claude", "settings.json"),
        os.path.join(path, ".claude", "settings.local.json"),
    ):
        block = read_json(candidate, {}).get("permissions")
        if not isinstance(block, dict):
            continue
        found = block.get(kind)
        if isinstance(found, list):
            rules.extend(r for r in found if isinstance(r, str))
    return rules


def rule_subject(tool, payload):
    """The part of the call a rule is written about."""
    data = payload.get("tool_input")
    if not isinstance(data, dict):
        return None
    value = data.get("command") if tool == "Bash" else (
        data.get("file_path") or data.get("path") or data.get("notebook_path")
    )
    return value if isinstance(value, str) else None


def rule_matches(rule, tool, payload):
    """Whether one rule covers this call.

    Partial on purpose: only the shapes whose meaning is unambiguous — a bare
    tool name, an exact argument, and a trailing `*` used as a prefix. Path
    globs are not attempted at all, because `//` and `**` carry a meaning worth
    getting exactly right and guessing at it would be worse than not trying.
    Anything unrecognised counts as no match.
    """
    if rule == tool:
        return True
    if not (rule.startswith(tool + "(") and rule.endswith(")")):
        return False
    inner = rule[len(tool) + 1:-1]

    subject = rule_subject(tool, payload)
    if subject is None:
        return False

    for suffix in (":*", " *", "*"):
        if inner.endswith(suffix):
            prefix = inner[: -len(suffix)]
            # Only for commands: a prefix over a path would have to understand
            # the glob syntax, and half-understanding it is the dangerous kind.
            return tool == "Bash" and bool(prefix) and subject.startswith(prefix)
    return subject == inner


def would_be_asked(tool, payload, path):
    """Whether Claude Code would actually stop and ask about this call.

    The precedence is Claude Code's own: `deny` refuses without asking, `ask`
    always asks, `allow` runs without a word.
    """
    mode = payload.get("permission_mode")
    if mode is not None and mode not in ASKING_MODES:
        return False
    if mode == "acceptEdits" and tool in ("Write", "Edit", "NotebookEdit"):
        return False

    if any(rule_matches(r, tool, payload) for r in permission_rules(path, "deny")):
        return False
    if any(rule_matches(r, tool, payload) for r in permission_rules(path, "ask")):
        return True
    if any(rule_matches(r, tool, payload) for r in permission_rules(path, "allow")):
        return False
    return True


def still_away():
    """Whether the app still says nobody is at the Mac."""
    return bool(read_json(CONFIG, {}).get("away"))


def still_holding(path):
    """Se le condizioni che giustificavano l'attesa valgono ancora.

    Riletto a ogni giro, perché entrambe cadono da sole: si torna alla tastiera,
    oppure si porta avanti la finestra coperta. In tutti e due i casi l'attesa
    deve finire subito — la prima è la ragione per cui era lunga, la seconda è la
    ragione per cui esisteva.
    """
    config = read_json(CONFIG, {})
    if config.get("away"):
        return True
    return path in (config.get("covered_projects") or [])


def gating(tool, payload, path):
    """Se questa chiamata va trattenuta. Involucro booleano di `hold_reason`."""
    return hold_reason(tool, payload, path) is not None


def hold_reason(tool, payload, path):
    """Perché trattenere questa chiamata, o `None` per non trattenerla.

    Only while the app says the user is away. `PreToolUse` fires for every tool
    call, so gating unconditionally would stop a session dead at each step — and
    when the user is at the Mac there is nothing to gain, because Claude Code's
    own prompt is right there in front of them.

    This exists because `PermissionRequest` never fires: measured on 2026-08-19,
    a real permission prompt raises `Notification` with no `tool_use_id`, which
    is nothing a remote answer can be addressed to. `PreToolUse` does fire, does
    carry the id, and its decision is honoured.

    And only for calls that would genuinely be asked about. Holding every call
    was the first version and it was wrong in a way that undid the whole point:
    on 2026-08-20 Stefano watched a session from the sofa sitting still, asking
    him to approve commands Claude Code would have run without a word — the mode
    was automatic and three hundred of his own rules already allowed them. The
    payload carried `permission_mode` all along, and this function had never
    looked at it.
    """
    if not tool:
        return None
    tools = config_gated_tools()
    if tool not in tools:
        return None
    if not would_be_asked(tool, payload, path):
        return None

    config = read_json(CONFIG, {})
    if config.get("away"):
        return "away"

    # Al Mac, ma con la finestra di quel progetto coperta da altre: il prompt nel
    # terminale c'è e non si vede. Il pannello invece è sempre in cima allo
    # schermo, quindi è il posto più veloce per rispondere, non il più lento.
    #
    # Solo *coperta*, non «non in primo piano»: con due schermi una finestra non
    # attiva è visibilissima, e trattenere lì significherebbe togliere il prompt
    # da sotto gli occhi di chi lo sta guardando.
    if path in (config.get("covered_projects") or []):
        return "covered"

    return None


def config_gated_tools():
    tools = read_json(CONFIG, {}).get("gated_tools")
    if not isinstance(tools, list) or not tools:
        return DEFAULT_GATED_TOOLS
    return tools


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


def emit_decision(behavior, event):
    """Prints the decision in the shape Claude Code expects for this event.

    The two events want different shapes, and getting it wrong is silent: the
    hook looks like it answered and the prompt appears anyway.
    """
    if event == "PreToolUse":
        payload = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": behavior,
                "permissionDecisionReason": "Risposto dall'iPhone tramite Claude Live",
            }
        }
    else:
        payload = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": behavior},
            }
        }
    json.dump(payload, sys.stdout)
    sys.stdout.flush()


def await_decision(request_id, timeout, tool=None, path=None):
    """Polls for the app's answer. Returns (behavior, remember) or None.

    Gives up early if the user comes back to the Mac. The app clears `away` the
    moment it sees input again, and continuing to hold the call would leave
    Claude frozen with the person who could answer it sitting right there — the
    exact situation the whole away/home distinction exists to avoid.
    """
    # Non chiamare questo `path`: il percorso del progetto arriva come parametro
    # con quel nome, e sovrascriverlo faceva chiedere a still_holding() se fosse
    # coperto un file di risposta invece di una finestra. Rispondeva no, e ogni
    # attesa «finestra coperta» finiva al primo giro. Nomi distinti, allora.
    decision_file = os.path.join(DECISIONS_DIR, f"{request_id}.json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if tool is not None and path is not None and not still_holding(path):
            return None
        if os.path.exists(decision_file):
            answer = read_json(decision_file, {})
            try:
                os.remove(decision_file)
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
    tool = payload.get("tool_name") or ""

    # Two ways to end up asking the user. `PermissionRequest` is the one this was
    # built for and the one that never fires; `PreToolUse` while away is the one
    # that works. Everything downstream treats them the same.
    reason = hold_reason(tool, payload, path) if event == "PreToolUse" else None
    is_permission = event == "PermissionRequest" or reason is not None

    summary = tool_summary(payload) if is_permission else None
    request_id = payload.get("tool_use_id") or ""
    fingerprint = request_fingerprint(path, tool, payload) if is_permission else None

    # An identical request the user already chose to always allow: answer at once
    # and leave the session marked as working rather than waiting.
    if is_permission and fingerprint and allowlisted(fingerprint):
        emit_decision("allow", event)
        state = "working"
        is_permission = False

    # A held tool call is the session waiting on a person, whatever the event
    # that carried it was called.
    if is_permission:
        state = "waiting_input"

    timeout = wait_seconds(reason or "away") if is_permission else 0
    decidable = bool(is_permission and request_id and timeout > 0 and app_is_running())

    # Un trattenimento che non offre pulsanti è il difetto più difficile di tutto
    # questo impianto: quattro condizioni concorrono e nessuna lasciava traccia,
    # quindi una risposta mancante non era distinguibile da un'altra. Ci sono
    # voluti quattro tentativi il 2026-08-21.
    #
    # Registrato solo quando succede: se il meccanismo funziona questo file non
    # esiste, e la sua presenza è già metà della diagnosi.
    # Il caso che vale la pena registrare non è quello che funziona, è quello in
    # cui c'era una domanda da girare al pannello e non l'abbiamo girata. Scritto
    # solo allora: un diario che registra tutto è un diario che nessuno legge, e
    # per una settimana ha nascosto qui in mezzo la riga che serviva.
    if is_permission and not decidable:
        try:
            log = os.path.join(HUB, "gate.log")
            if not os.path.exists(log) or os.path.getsize(log) < 512 * 1024:
                with open(log, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps({
                        "at": time.strftime("%Y-%m-%d %H:%M:%S"),
                        "project": os.path.basename(path),
                        "event": event,
                        "tool": tool,
                        "mode": payload.get("permission_mode"),
                        # Perché non era rispondibile: manca il motivo per
                        # trattenere, l'identificativo della richiesta, o l'app.
                        "reason": reason,
                        "has_request_id": bool(request_id),
                        "app_running": app_is_running(),
                    }) + "\n")
        except Exception:
            pass

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
        # Fino a quando questa richiesta è rispondibile. Serve a difenderla da chi
        # scrive dopo.
        "hold_until": (time.time() + timeout) if decidable else 0,
        "updated_at_epoch": time.time(),
        "pid": os.getpid(),
    }

    # Un record rispondibile non si lascia sovrascrivere da uno che non lo è.
    #
    # `PermissionRequest` scatta *insieme* a `PreToolUse` — misurato il 2026-08-21,
    # due righe con lo stesso secondo — e non porta il `tool_use_id`, quindi
    # descrive la stessa domanda in una forma a cui nessuno può rispondere. C'è un
    # file di stato per sessione e vince l'ultimo che scrive: il pannello leggeva
    # quello e non trovava nulla da offrire, mentre l'hook era lì che aspettava.
    #
    # Va detto che il commento di `gating` sostiene il contrario, sulla base di una
    # misura del 19 agosto: `PermissionRequest` non scattava. Adesso scatta.
    #
    # Solo mentre l'attesa è in corso: quando scade, il record *deve* smettere di
    # dirsi rispondibile, e allora la sovrascrittura è quella giusta.
    if event in ("PermissionRequest", "Notification") and not decidable:
        existing = read_json(target, {})
        if existing.get("decidable") and float(existing.get("hold_until") or 0) > time.time():
            return

    write_atomic(target, record)

    if not decidable:
        return

    # Il file che il pannello legge per offrire i pulsanti. Vive quanto l'attesa.
    pending_file = os.path.join(PENDING_DIR, f"{request_id}.json")
    write_atomic(pending_file, {
        "request_id": request_id,
        "project_path": path,
        "project_name": os.path.basename(path.rstrip("/")) if path else "",
        "session_id": session,
        "tool_name": tool or "",
        "tool_summary": summary,
        "reason": reason,
        "hold_until": time.time() + timeout,
        "at": time.time(),
    })
    try:
        answer = await_decision(
            request_id, timeout, tool if event == "PreToolUse" else None, path
        )
    finally:
        # In ogni caso: risposta data, attesa scaduta, o errore. Un file rimasto
        # qui offrirebbe un pulsante per una domanda che non aspetta più nessuno.
        try:
            os.remove(pending_file)
        except OSError:
            pass
    if answer is None:
        # No answer in time: print nothing, so Claude Code prompts in the terminal
        # exactly as it would without this hook.
        record["decidable"] = False
        record["hold_until"] = 0
        record["updated_at_epoch"] = time.time()
        write_atomic(target, record)
        return

    behavior, should_remember = answer
    if behavior == "allow" and should_remember and fingerprint:
        remember(fingerprint, path, tool, summary or tool)

    emit_decision(behavior, event)

    # The answer was given, so the session is no longer waiting on the user.
    record["state"] = "working" if behavior == "allow" else "idle"
    record["decidable"] = False
    record["hold_until"] = 0
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
