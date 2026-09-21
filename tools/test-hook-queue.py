#!/usr/bin/env python3
"""La coda: scritto mentre Claude lavora, consegnato appena finisce.

Perché esiste: è l'unico modo di scrivere dentro una conversazione viva
**stando al Mac**. L'attesa da lontano (`test-hook-prompt.py`) per costruzione
non si apre quando sei alla tastiera, quindi la barra della mascotte non può
appoggiarsi a quella. Qui il messaggio è già scritto quando il turno finisce:
non c'è niente da aspettare, c'è solo da consegnarlo.

Ogni pezzo di questa catena è invisibile se si rompe — il file che l'hook non
legge, il messaggio consegnato due volte, quello vecchio di un'ora che ricompare
in bocca a una conversazione andata da un'altra parte. Claude Code accetta in
silenzio un'uscita malformata e chiude il turno come se non avessimo parlato.

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
                  ("PENDING_DIR", "pending"), ("QUEUE_DIR", "queue")):
    path = os.path.join(hub, sub)
    os.makedirs(path, exist_ok=True)
    setattr(hook, name, path)

PROJECT = "/Users/tizio/Repository/sito-esempio"
SESSION = "prova-coda"
MESSAGGIO = "Ora aggiungi i test per il carrello."
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


def stop_payload(session=SESSION):
    return {
        "hook_event_name": "Stop",
        "session_id": session,
        "cwd": PROJECT,
        "stop_hook_active": False,
        "last_assistant_message": "Fatto, ho scritto la homepage.",
    }


def queue_file(session=SESSION):
    """Dove la mascotte lascia il messaggio: lo stesso nome che usa l'app."""
    safe = "".join(c for c in str(session) if c.isalnum() or c in "-_")[:40]
    return os.path.join(hook.QUEUE_DIR, "%s.json" % safe)


def enqueue(text, age=0, session=SESSION):
    with open(queue_file(session), "w") as handle:
        json.dump({"prompt": text, "at": time.time() - age}, handle)


def status_record(session=SESSION):
    for name in os.listdir(hook.STATUS_DIR):
        record = json.load(open(os.path.join(hook.STATUS_DIR, name)))
        if record.get("session_id") == session:
            return record
    return {}


def run_main(data):
    hook.read_payload = lambda: data
    buffer = io.StringIO()
    started = time.time()
    with contextlib.redirect_stdout(buffer):
        hook.main()
    return buffer.getvalue().strip(), time.time() - started


# --- Il caso normale: al Mac, Claude finisce, il messaggio parte -------------
#
# `away` deliberatamente falso: è tutto il punto. Questa strada deve funzionare
# proprio nella situazione in cui l'attesa da lontano non si apre.

config(away=False, prompt_wait_seconds=0)
heartbeat()
enqueue(MESSAGGIO)
out, elapsed = run_main(stop_payload())

check(out != "", "il messaggio in coda non ha fatto ripartire il turno")
if out:
    payload = json.loads(out)
    check(payload.get("decision") == "block",
          "l'uscita non dice a Claude Code di continuare: %r" % payload.get("decision"))
    check(payload.get("reason") == MESSAGGIO,
          "è arrivato un testo diverso da quello scritto: %r" % payload.get("reason"))

check(elapsed < 1, "ha aspettato %.1fs: la coda non deve aspettare niente" % elapsed)
check(not os.path.exists(queue_file()), "il messaggio è rimasto in coda dopo la consegna")
check(status_record().get("state") == "working",
      "dopo la ripartenza lo stato dice ancora «%s»" % status_record().get("state"))

# --- Consegnato una volta sola ----------------------------------------------
#
# Il caso che fa più danno: lo stesso messaggio infilato di nuovo alla fine del
# turno successivo, cioè una conversazione che si rimette in moto da sola.

out, elapsed = run_main(stop_payload())
check(out == "", "il messaggio è stato consegnato due volte")

# --- Senza niente in coda, un turno finisce come sempre ----------------------

config(away=False)
heartbeat()
out, elapsed = run_main(stop_payload())
check(out == "", "senza niente in coda ha comunque fatto ripartire il turno")
check(elapsed < 1, "senza niente in coda ha aspettato %.1fs" % elapsed)

# --- Un messaggio vecchio non si consegna, ma sparisce -----------------------

enqueue(MESSAGGIO, age=hook.QUEUED_PROMPT_MAX_AGE + 60)
out, elapsed = run_main(stop_payload())
check(out == "", "un messaggio di mezz'ora fa è stato consegnato lo stesso")
check(not os.path.exists(queue_file()),
      "un messaggio scaduto è rimasto lì ad aspettare il turno dopo")

# --- Testi che non sono testi ------------------------------------------------

for bogus in ("   ", "", 42, None):
    enqueue(bogus)
    out, elapsed = run_main(stop_payload())
    check(out == "", "un messaggio %r ha fatto ripartire il turno" % (bogus,))
    check(not os.path.exists(queue_file()), "un messaggio %r è rimasto in coda" % (bogus,))

# Un file illeggibile non deve far esplodere l'hook: l'hook gira dentro Claude
# Code, e un'eccezione qui è un turno che non finisce.
with open(queue_file(), "w") as handle:
    handle.write("{ questo non è json")
out, elapsed = run_main(stop_payload())
check(out == "", "un file di coda illeggibile ha fatto ripartire il turno")

# --- Un testo lunghissimo viene tagliato, non rifiutato ----------------------

enqueue("x" * 9000)
out, elapsed = run_main(stop_payload())
if out:
    reason = json.loads(out).get("reason") or ""
    check(len(reason) == hook.MAX_PROMPT_CHARACTERS,
          "un testo lunghissimo è arrivato lungo %d" % len(reason))
else:
    fails.append("un testo lunghissimo non ha fatto ripartire il turno")

# --- La coda è per sessione, non per progetto --------------------------------
#
# Due chat aperte sullo stesso progetto sono due conversazioni: il messaggio
# scritto per una non deve finire nell'altra.

enqueue(MESSAGGIO, session="altra-sessione")
out, elapsed = run_main(stop_payload())
check(out == "", "il messaggio di un'altra sessione è finito in questa")
check(os.path.exists(queue_file("altra-sessione")),
      "il messaggio dell'altra sessione è stato consumato da questa")

print("\n".join("  ✗ " + f for f in fails) if fails
      else "  ✓ tutte le verifiche passate (coda della mascotte)")
sys.exit(1 if fails else 0)
