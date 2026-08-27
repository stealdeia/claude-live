#!/usr/bin/env python3
"""Le domande a scelta multipla si trattengono e si rispondono dal pannello.

Perché esiste: una domanda non è un permesso, e il resto dell'hook è costruito
per i permessi. Se passasse dalle stesse condizioni — modalità, regole di
`allow` — in automatico non verrebbe trattenuta mai, che è proprio il caso in
cui è l'unica cosa che aspetta una persona.

La prova gira l'hook per davvero, con le sue costanti dirottate in una cartella
temporanea: niente finto, solo isolato.
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "Resources", "claude-hub-status.py")

spec = importlib.util.spec_from_file_location("hook", SRC)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

hub = tempfile.mkdtemp()
hook.HUB = hub
hook.CONFIG = os.path.join(hub, "config.json")
hook.HEARTBEAT = os.path.join(hub, "app-heartbeat")
hook.ALLOWLIST = os.path.join(hub, "allowlist.json")
for name, sub in (("STATUS_DIR", "status"), ("DECISIONS_DIR", "decisions"),
                  ("PENDING_DIR", "pending")):
    path = os.path.join(hub, sub)
    os.makedirs(path, exist_ok=True)
    setattr(hook, name, path)

PROJECT = "/Users/tizio/Repository/sito-esempio"
QUESTION = "Con quale grafica procedo per la homepage?"
fails = []


def check(condition, message):
    if not condition:
        fails.append(message)


def config(**kw):
    with open(hook.CONFIG, "w") as handle:
        json.dump(kw, handle)


def heartbeat():
    """L'app è viva: senza questo nessuna richiesta è rispondibile."""
    with open(hook.HEARTBEAT, "w") as handle:
        json.dump({"at": time.time(), "pid": os.getpid()}, handle)


def payload(mode="default", questions=None, tool=hook.QUESTION_TOOL):
    return {
        "hook_event_name": "PreToolUse",
        "session_id": "prova-domande",
        "cwd": PROJECT,
        "tool_name": tool,
        "tool_use_id": "toolu_prova_domanda",
        "permission_mode": mode,
        "tool_input": {"questions": questions if questions is not None else [{
            "question": QUESTION,
            "header": "Grafica",
            "multiSelect": False,
            "options": [
                {"label": "Sobria", "description": "Bianco, poco colore."},
                {"label": "Accesa", "description": "Colori pieni, contrasti."},
            ],
        }]},
    }


# --- Leggere la domanda ------------------------------------------------------

found = hook.questions_of(payload())
check(len(found) == 1, f"una domanda letta come {len(found)}")
check(found and found[0]["question"] == QUESTION, "il testo della domanda non torna")
check(found and [o["label"] for o in found[0]["options"]] == ["Sobria", "Accesa"],
      "le opzioni non tornano")
check(found and found[0]["multi"] is False, "scelta singola letta come multipla")

check(hook.questions_of(payload(questions=[{"question": "Senza opzioni?"}])) == [],
      "una domanda senza opzioni non va offerta: non c'è niente da premere")
check(hook.questions_of({"tool_input": {}}) == [], "input vuoto non gestito")

# --- Trattenere, e solo quando serve ----------------------------------------

# Il caso che prima non arrivava mai: modalità automatica.
for mode in ("auto", "bypassPermissions", "plan", "acceptEdits", "default", None):
    config(away=False, covered_projects=[PROJECT])
    got = hook.hold_reason(hook.QUESTION_TOOL, payload(mode=mode), PROJECT)
    check(got == "covered",
          f"domanda in modalità {mode!r}: trattenuta come {got!r} invece di 'covered'")

config(away=True, covered_projects=[])
check(hook.hold_reason(hook.QUESTION_TOOL, payload(mode="auto"), PROJECT) == "away",
      "domanda mentre l'utente è via: non trattenuta")

# Finestra in vista e utente presente: la domanda sta nel terminale, davanti a lui.
config(away=False, covered_projects=[])
check(hook.hold_reason(hook.QUESTION_TOOL, payload(), PROJECT) is None,
      "domanda trattenuta con la finestra in vista: il terminale è davanti a lui")

# Un permesso in automatico resta escluso: quella regola non deve essere caduta.
config(away=False, covered_projects=[PROJECT])
check(hook.hold_reason("Bash", {**payload(mode="auto", tool="Bash"),
                                "tool_input": {"command": "ls"}}, PROJECT) is None,
      "un permesso in modalità automatica non va trattenuto")

# --- Il tempo concesso ------------------------------------------------------

config(away=False, covered_projects=[PROJECT])
check(hook.wait_seconds("covered", question=True) == 180,
      "una domanda ha tre minuti, non i 45 secondi di un permesso")
check(hook.wait_seconds("covered") == 45, "il permesso non deve aver cambiato attesa")

# --- Rispondere -------------------------------------------------------------

buffer = io.StringIO()
with contextlib.redirect_stdout(buffer):
    hook.emit_answers(payload(), {QUESTION: "Accesa"})
emitted = json.loads(buffer.getvalue())
spec_out = emitted.get("hookSpecificOutput") or {}
check(spec_out.get("hookEventName") == "PreToolUse", "evento sbagliato nella risposta")
check(spec_out.get("permissionDecision") == "allow",
      "la risposta deve consentire la chiamata, non negarla")
updated = spec_out.get("updatedInput") or {}
check(updated.get("answers") == {QUESTION: "Accesa"},
      f"risposte consegnate come {updated.get('answers')!r}")
check("questions" in updated,
      "l'input riscritto deve conservare le domande, non solo le risposte")

# --- Tutto insieme, dall'inizio alla fine -----------------------------------

config(away=False, covered_projects=[PROJECT], question_wait_seconds=6)
heartbeat()
data = payload(mode="auto")
hook.read_payload = lambda: data


def answer_from_panel():
    """Fa quello che farà il pannello: legge la richiesta e scrive la scelta."""
    for _ in range(120):
        files = os.listdir(hook.PENDING_DIR)
        if files:
            request = json.load(open(os.path.join(hook.PENDING_DIR, files[0])))
            check(request.get("kind") == "question",
                  f"la richiesta si dichiara {request.get('kind')!r} invece di 'question'")
            check(len(request.get("questions") or []) == 1,
                  "la richiesta non porta la domanda da mostrare")
            with open(os.path.join(hook.DECISIONS_DIR,
                                   f"{request['request_id']}.json"), "w") as handle:
                json.dump({"answers": {QUESTION: "Sobria"}}, handle)
            return
        time.sleep(0.05)
    fails.append("nessuna richiesta è comparsa per il pannello")


worker = threading.Thread(target=answer_from_panel, daemon=True)
worker.start()
buffer = io.StringIO()
started = time.time()
with contextlib.redirect_stdout(buffer):
    hook.main()
worker.join(timeout=2)
elapsed = time.time() - started

check(elapsed < 5, f"l'hook ha aspettato {elapsed:.1f}s invece di rispondere subito")
out = buffer.getvalue().strip()
if not out:
    fails.append("l'hook non ha consegnato niente a Claude Code")
else:
    final = json.loads(out).get("hookSpecificOutput") or {}
    check(final.get("permissionDecision") == "allow", "la chiamata non è stata consentita")
    check((final.get("updatedInput") or {}).get("answers") == {QUESTION: "Sobria"},
          "la scelta del pannello non è arrivata nell'input")
check(os.listdir(hook.PENDING_DIR) == [],
      "la richiesta è rimasta lì dopo la risposta")

print("\n".join("  ✗ " + f for f in fails) if fails
      else "  ✓ tutte le verifiche passate (domande a scelta multipla)")
sys.exit(1 if fails else 0)
