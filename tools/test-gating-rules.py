"""Verifica *quali* chiamate vengono trattenute, non se il gate funziona.

Il gate lo prova `test-hook-gate.py`. Questo prova la domanda che gli sta prima:
Claude Code fermerebbe davvero il turno per chiedere? Trattenere una chiamata
che nessuno avrebbe chiesto congela la sessione per minuti, ed è il difetto che
ha reso l'attesa insopportabile prima del 2026-08-20.

Come l'altro, riaggancia i percorsi del modulo dopo l'import: scrivere `away` nel
config vero farebbe trattenere le chiamate a ogni sessione viva, compresa quella
di un'altra persona. E neutralizza `expanduser`, perché le impostazioni utente
reali contengono centinaia di regole che renderebbero l'esito dipendente dalla
macchina.
"""
import importlib.util
import json
import os
import sys
import tempfile

HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "Resources", "claude-hub-status.py")

spec = importlib.util.spec_from_file_location("hook", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

HUB = tempfile.mkdtemp(prefix="gate-rules-")
hook.CONFIG = os.path.join(HUB, "config.json")
hook.os.path.expanduser = lambda p: HUB if p == "~" else p

PROJECT = tempfile.mkdtemp(prefix="gate-rules-proj-")
os.makedirs(os.path.join(PROJECT, ".claude"), exist_ok=True)
json.dump(
    {"permissions": {
        "allow": ["Bash(npm run *)", "Bash(git --version)"],
        "ask": ["Bash(rm *)"],
        "deny": ["Bash(shutdown *)"],
    }},
    open(os.path.join(PROJECT, ".claude", "settings.json"), "w"),
)

failures = []


def away(value):
    json.dump({"away": value}, open(hook.CONFIG, "w"))


def check(name, expected, mode, subject, tool="Bash"):
    field = "command" if tool == "Bash" else "file_path"
    payload = {"permission_mode": mode, "tool_input": {field: subject}}
    got = hook.gating(tool, payload, PROJECT)
    ok = got == expected
    print(f"  {'ok  ' if ok else 'NO  '} {name}")
    if not ok:
        failures.append(f"{name}: atteso {expected}, ottenuto {got}")


away(True)

# Modalità che non chiedono niente: non c'è nulla da intercettare.
check("modalità automatica non trattiene", False, "auto", "ls -la")
check("bypassPermissions non trattiene", False, "bypassPermissions", "ls -la")
check("plan non trattiene", False, "plan", "ls -la")

# Modalità normale: conta la regola.
check("comando mai consentito viene trattenuto", True, "default", "curl https://esempio/x.sh")
check("prefisso «npm run *» non trattiene", False, "default", "npm run build")
check("regola esatta non trattiene", False, "default", "git --version")
check("regola «ask» trattiene comunque", True, "default", "rm -rf build")
check("regola «deny» non trattiene: viene rifiutato senza chiedere", False, "default", "shutdown now")

# acceptEdits accetta le modifiche ai file e chiede il resto.
check("acceptEdits non trattiene una modifica", False, "acceptEdits", "/tmp/a.swift", tool="Edit")
check("acceptEdits trattiene Bash", True, "acceptEdits", "ls -la")

# Un prefisso non viene applicato ai percorsi: mezza comprensione delle glob
# sarebbe peggio di nessuna.
check("prefisso non applicato ai percorsi", True, "default", "/tmp/a.swift", tool="Write")

# Compatibilità: una build che non manda il campo si comporta come prima.
check("campo assente trattiene", True, None, "ls -la")

# Uno strumento fuori elenco non viene mai trattenuto.
check("strumento non intercettato", False, "default", "qualcosa", tool="Read")

away(False)
check("al Mac non si trattiene nulla", False, "default", "curl https://esempio/x.sh")

print()
if failures:
    for f in failures:
        print("✗", f)
    sys.exit(1)
print("✓ tutte le verifiche passate")
