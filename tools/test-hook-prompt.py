#!/usr/bin/env python3
"""Il turno finito si trattiene, e dal telefono riparte.

Perché esiste: è l'unico punto in cui si può scrivere dentro una conversazione
viva di VS Code. `Stop` scatta a turno finito e `decision: block` lo fa
ripartire — stessa sessione, nessuno stacco, nessuna biforcazione. Ogni pezzo
di quella catena è invisibile se si rompe: l'hook che non trattiene, il file che
il telefono non trova, l'uscita nella forma sbagliata. Claude Code accetta in
silenzio una risposta malformata e chiude il turno come se non avessimo parlato.

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
SESSION = "prova-seguito"
SEGUITO = "Bene, ora aggiungi anche il footer con i contatti."
fails = []


def check(condition, message):
    if not condition:
        fails.append(message)


def config(**kw):
    with open(hook.CONFIG, "w") as handle:
        json.dump(kw, handle)


def heartbeat(alive=True):
    with open(hook.HEARTBEAT, "w") as handle:
        json.dump({"at": time.time() if alive else 0, "pid": os.getpid()}, handle)


def stop_payload():
    return {
        "hook_event_name": "Stop",
        "session_id": SESSION,
        "cwd": PROJECT,
        "stop_hook_active": False,
        "last_assistant_message": "Fatto, ho scritto la homepage.",
    }


def status_record():
    """Il file di stato che l'hook ha lasciato per questa sessione."""
    for name in os.listdir(hook.STATUS_DIR):
        record = json.load(open(os.path.join(hook.STATUS_DIR, name)))
        if record.get("session_id") == SESSION:
            return record
    return {}


def run_main(data, answer=None, timeout=6):
    """Gira l'hook mentre qualcun altro fa la parte del telefono.

    Restituisce (uscita, secondi, richiesta_vista_dal_telefono).
    """
    hook.read_payload = lambda: data
    seen = {}

    def phone():
        for _ in range(int(timeout * 20)):
            files = [f for f in os.listdir(hook.PENDING_DIR) if f.startswith("prompt-")]
            if files:
                request = json.load(open(os.path.join(hook.PENDING_DIR, files[0])))
                seen.update(request)
                if answer is not None:
                    with open(os.path.join(hook.DECISIONS_DIR,
                                           "%s.json" % request["request_id"]), "w") as h:
                        json.dump(answer, h)
                return
            time.sleep(0.05)

    worker = threading.Thread(target=phone, daemon=True)
    worker.start()
    buffer = io.StringIO()
    started = time.time()
    with contextlib.redirect_stdout(buffer):
        hook.main()
    # Misurato qui e non dopo il `join`: quanto è durata l'attesa è il punto di
    # metà di queste verifiche, e aspettare il thread che fa da telefono
    # aggiungerebbe il suo tempo a quello dell'hook.
    elapsed = time.time() - started
    worker.join(timeout=2)
    return buffer.getvalue().strip(), elapsed, seen


# --- Quando si trattiene, e quando no ----------------------------------------

# Spento di default: chi aggiorna l'hook senza volere questa funzione non deve
# ritrovarsi il Mac che trattiene la fine di ogni turno.
config(away=True)
check(hook.wait_seconds("prompt") == 0,
      "senza configurazione l'attesa del seguito deve essere spenta")

config(away=True, prompt_wait_seconds=3300)
check(hook.wait_seconds("prompt") == 3300, "l'attesa configurata non viene letta")
check(hook.wait_seconds("covered") == 45,
      "il permesso non deve aver cambiato attesa")
check(hook.wait_seconds("covered", question=True) == 180,
      "la domanda non deve aver cambiato attesa")

# Seduti al Mac non si trattiene: Claude sembrerebbe non finire mai.
config(away=False, prompt_wait_seconds=3300)
heartbeat()
out, elapsed, seen = run_main(stop_payload())
check(elapsed < 1, "ha trattenuto il turno con l'utente seduto al Mac (%.1fs)" % elapsed)
check(out == "", "ha parlato a Claude Code quando non doveva")
check(status_record().get("prompt_request_id") == "",
      "si è dichiarato in attesa mentre l'utente era al Mac")

# App spenta: nessuno potrebbe rispondere.
config(away=True, prompt_wait_seconds=3300)
heartbeat(alive=False)
out, elapsed, seen = run_main(stop_payload())
check(elapsed < 1, "ha trattenuto il turno con l'app spenta (%.1fs)" % elapsed)

# --- L'attesa vera, e il seguito che arriva ----------------------------------

config(away=True, prompt_wait_seconds=6)
heartbeat()
out, elapsed, seen = run_main(stop_payload(), answer={"prompt": SEGUITO})

check(elapsed < 5, "ha aspettato %.1fs invece di ripartire subito" % elapsed)
check(seen.get("kind") == "prompt",
      "la richiesta si dichiara %r invece di 'prompt'" % seen.get("kind"))
check(seen.get("session_id") == SESSION,
      "la richiesta non porta la sessione a cui scrivere")
check(seen.get("project_name") == "sito-esempio",
      "la richiesta non porta il nome del progetto")

if not out:
    fails.append("l'hook non ha detto niente a Claude Code: il turno è finito lì")
else:
    emitted = json.loads(out)
    # La forma è verificata dentro il programma di Claude Code: `decision` e
    # `reason` al primo livello, non dentro `hookSpecificOutput`. Sbagliarla non
    # dà errore, chiude il turno in silenzio.
    check(emitted.get("decision") == "block",
          "uscita %r: il turno non riparte" % emitted.get("decision"))
    check(emitted.get("reason") == SEGUITO,
          "il testo arrivato a Claude è %r" % emitted.get("reason"))
    check("hookSpecificOutput" not in emitted,
          "`Stop` non usa hookSpecificOutput: quella forma verrebbe ignorata")

after = status_record()
check(after.get("state") == "working",
      "dopo il seguito la sessione si dichiara %r invece di 'working'" % after.get("state"))
check(after.get("prompt_request_id") == "",
      "l'attesa risulta ancora aperta dopo aver risposto")
check([f for f in os.listdir(hook.PENDING_DIR) if f.startswith("prompt-")] == [],
      "la richiesta è rimasta lì dopo il seguito")

# --- L'attesa che scade ------------------------------------------------------

config(away=True, prompt_wait_seconds=1)
heartbeat()
out, elapsed, seen = run_main(stop_payload(), answer=None, timeout=3)
check(out == "",
      "attesa scaduta: non deve stampare niente, o il turno riparte a vuoto")
check(1 <= elapsed < 3, "l'attesa è durata %.1fs invece di ~1s" % elapsed)
check(status_record().get("state") == "idle",
      "dopo un'attesa scaduta la sessione deve restare ferma")

# --- Si torna al Mac: l'attesa si chiude subito ------------------------------

config(away=True, prompt_wait_seconds=30)
heartbeat()
hook.read_payload = lambda: stop_payload()


def comes_home():
    time.sleep(0.4)
    config(away=False, prompt_wait_seconds=30)


threading.Thread(target=comes_home, daemon=True).start()
buffer = io.StringIO()
started = time.time()
with contextlib.redirect_stdout(buffer):
    hook.main()
elapsed = time.time() - started
check(elapsed < 5,
      "tornato al Mac, l'attesa è durata %.1fs invece di chiudersi subito" % elapsed)
check(buffer.getvalue().strip() == "", "ha fatto ripartire il turno senza un seguito")

# --- Un seguito vuoto o assurdo non fa ripartire niente ----------------------

for bogus in ({"prompt": "   "}, {"prompt": ""}, {"prompt": 42}, {}):
    config(away=True, prompt_wait_seconds=2)
    heartbeat()
    out, elapsed, seen = run_main(stop_payload(), answer=bogus, timeout=3)
    check(out == "", "un seguito %r ha fatto ripartire il turno" % (bogus,))

# --- Un testo lunghissimo viene tagliato, non rifiutato ----------------------

config(away=True, prompt_wait_seconds=4)
heartbeat()
out, elapsed, seen = run_main(stop_payload(), answer={"prompt": "x" * 9000})
if out:
    reason = json.loads(out).get("reason") or ""
    check(len(reason) == hook.MAX_PROMPT_CHARACTERS,
          "un testo lunghissimo è arrivato lungo %d" % len(reason))
else:
    fails.append("un testo lunghissimo non ha fatto ripartire il turno")

print("\n".join("  ✗ " + f for f in fails) if fails
      else "  ✓ tutte le verifiche passate (seguito dal telefono)")
sys.exit(1 if fails else 0)
