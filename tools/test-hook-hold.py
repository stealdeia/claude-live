"""L'attesa dura quanto la ragione che l'ha giustificata, non un giro solo."""
import importlib.util, json, os, sys, tempfile, threading, time

src = "/Users/stefanoaldeia/Repository Github/hub-claude/ClaudeLive/Resources/claude-hub-status.py"
spec = importlib.util.spec_from_file_location("hook", src)
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)

hub = tempfile.mkdtemp()
hook.CONFIG = os.path.join(hub, "config.json")
hook.DECISIONS_DIR = os.path.join(hub, "decisions"); os.makedirs(hook.DECISIONS_DIR)
project = "/Users/tizio/Repository/sito-esempio"
fails = []

def config(**kw): open(hook.CONFIG, "w").write(json.dumps(kw))

# 1. Finestra coperta, nessuna risposta: deve aspettare tutto il tempo concesso.
config(away=False, covered_projects=[project])
t = time.time(); hook.await_decision("r1", 1.5, tool="Bash", path=project)
waited = time.time() - t
if waited < 1.4: fails.append(f"attesa su finestra coperta durata {waited:.2f}s invece di 1.5s")

# 2. Finestra tornata in vista: deve smettere subito.
config(away=False, covered_projects=[])
t = time.time(); hook.await_decision("r2", 5, tool="Bash", path=project)
if time.time() - t > 1: fails.append("non ha smesso quando la finestra è tornata visibile")

# 3. Coperta, e la risposta arriva: deve leggerla e restituirla.
config(away=False, covered_projects=[project])
def answer():
    time.sleep(0.4)
    open(os.path.join(hook.DECISIONS_DIR, "r3.json"), "w").write(
        json.dumps({"behavior": "allow", "remember": True}))
threading.Thread(target=answer, daemon=True).start()
got = hook.await_decision("r3", 3, tool="Bash", path=project)
if got != ("allow", True): fails.append(f"risposta letta come {got!r} invece di ('allow', True)")

# 4. Sono via: aspetta anche se nessun progetto è coperto.
config(away=True, covered_projects=[])
t = time.time(); hook.await_decision("r4", 1.2, tool="Bash", path=project)
if time.time() - t < 1.1: fails.append("non ha aspettato mentre l'utente era via")

print("\n".join("  ✗ " + f for f in fails) if fails else "  ✓ 4 prove passate")
sys.exit(1 if fails else 0)
