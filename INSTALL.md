# Installare Claude Live

Pannello per la barra dei menu di macOS che mostra i limiti di utilizzo del tuo
account Claude e lo stato delle sessioni Claude Code nei progetti VS Code aperti.

## Cosa serve

- **macOS 14** (Sonoma) o successivo
- **Claude Code** installato e con il login effettuato — apri il Terminale, esegui
  `claude` e accedi. È da qui che l'app legge i tuoi livelli di utilizzo.
- **Visual Studio Code** — opzionale: serve solo per la lista progetti

Nessun dato lascia il tuo Mac. L'app legge le credenziali di Claude Code già
presenti nel tuo Keychain e le usa solo per chiedere all'API di Anthropic i tuoi
livelli di utilizzo.

## Installazione

### 1. Scarica e trascina

Apri il `.dmg` e trascina **Claude Live** nella cartella Applicazioni.

### 2. Autorizza l'app (una volta sola)

Al primo doppio clic macOS dirà che l'app **non può essere aperta perché proviene
da uno sviluppatore non identificato**.

È previsto: l'app è firmata ma non registrata presso Apple. Non è un errore.

Per autorizzarla:

1. Impostazioni di Sistema → **Privacy e Sicurezza**
2. Scorri in fondo: trovi *«Claude Live è stata bloccata per proteggere il Mac»*
3. Premi **Apri comunque** e conferma con Touch ID o password

Da quel momento l'app si apre normalmente, e **gli aggiornamenti successivi non
richiedono di ripetere questa procedura**.

> Su macOS 15 e successivi il vecchio metodo "clic destro → Apri" non funziona
> più: bisogna passare dalle Impostazioni di Sistema come sopra.

### 3. Segui la procedura guidata

Al primo avvio si apre una finestra che verifica i requisiti e chiede i permessi,
un passaggio per volta.

**Il punto a cui fare attenzione:** quando macOS chiede l'accesso al Keychain,
scegli **«Consenti sempre»**, non «Consenti».

![](#) Con «Consenti» la richiesta ricompare a ogni controllo, cioè ogni pochi
minuti — diventa inutilizzabile.

Gli altri passaggi:

| Passaggio | A cosa serve | Obbligatorio |
| --- | --- | --- |
| Accesso Keychain | Leggere i tuoi limiti di utilizzo | Sì |
| Hook di Claude Code | Stato per progetto (lavora / attende / fermo) | No |
| Notifiche | Avviso quando Claude aspetta una risposta | No |
| Avvio al login | Far partire l'app da sola | No |

Gli **hook** sono piccoli comandi che Claude Code esegue quando inizia a
lavorare, quando finisce o quando ti chiede un permesso. L'app li installa nel
tuo `~/.claude/settings.json` **facendone prima un backup** e senza toccare hook
che avessi già.

Se salti un passaggio, puoi riprendere in qualsiasi momento dal menu della barra:
**Configurazione guidata…**

## Come si usa

L'app **non ha icona nel Dock**: vive nella barra dei menu, icona **✦** con la
percentuale della sessione da 5 ore.

- **Clic sull'icona** → menu con riepilogo, progetti e impostazioni
- Un **pallino arancione** accanto alla percentuale significa che Claude aspetta
  una tua risposta in qualche progetto
- Il **pannello** si trascina dove vuoi; su un Mac col notch puoi agganciarlo lì
  (menu → *Passa al notch*)
- **Tema** chiaro / scuro / come il sistema in Impostazioni → Superficie

### Stato dei progetti

| Pallino | Significato |
| --- | --- |
| 🟢 verde pulsante | Claude sta lavorando (con il nome dello strumento in uso) |
| 🟠 arancione lampeggiante | Aspetta una tua risposta: permesso o domanda |
| ⚪️ grigio | Sessione aperta, in attesa |
| 🔴 rosso | Il turno è terminato con un errore |
| ⭕️ cerchio vuoto | Nessuna sessione, o stato non aggiornato da oltre 10 minuti |

## Aggiornamenti

Automatici: l'app controlla una volta al giorno e ti propone la nuova versione.
Puoi forzare il controllo dal menu → **Cerca aggiornamenti…**

## Se qualcosa non va

**Le barre di utilizzo sono vuote.** L'accesso al Keychain non è stato concesso,
oppure Claude Code non ha un login attivo. Riapri la *Configurazione guidata* dal
menu: il passaggio «Keychain» dice esattamente cosa manca.

**La richiesta del Keychain ricompare sempre.** È stato scelto «Consenti» invece
di «Consenti sempre». Apri *Accesso Portachiavi*, cerca `Claude Code-credentials`,
scheda *Controllo accessi*, e aggiungi Claude Live tra le app consentite.

**La lista progetti è vuota.** VS Code deve essere in esecuzione con almeno una
cartella aperta. La lista si aggiorna quando apri o chiudi una finestra; puoi
forzarla dal menu → *Aggiorna progetti*.

**I progetti non mostrano il pallino di stato.** Gli hook non sono installati, o
le sessioni Claude Code erano già aperte quando li hai installati: gli hook
vengono caricati all'avvio di una sessione, quindi riavvia `claude`.

**Diagnostica.** Impostazioni → Diagnostica → *Log di debug su file*, poi
*Apri log*. Il file è in
`~/Library/Application Support/ClaudeHub/logs/claudelive.log`.

## Disinstallare

1. Trascina `/Applications/Claude Live.app` nel Cestino
2. Rimuovi gli hook: nel Terminale,
   `/Applications/Claude\ Live.app/Contents/Resources/install-claude-hooks.py --uninstall`
   (se hai già eliminato l'app, rimuovi a mano le voci che contengono
   `claude-hub-status` da `~/.claude/settings.json`)
3. Facoltativo: elimina `~/Library/Application Support/ClaudeHub` e
   `~/.claude-hub`
