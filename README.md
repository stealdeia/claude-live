# Claude Live

Pannello macOS sempre visibile con i limiti di utilizzo dell'account Claude, i
progetti VS Code aperti e lo stato in tempo reale delle sessioni Claude Code.

App **menu bar only** (`LSUIElement`), macOS 14+, Swift/SwiftUI. Nessun dato lascia la macchina.

## Stato

| Fase | Contenuto | Stato |
| --- | --- | --- |
| 1 | Barre di utilizzo account (5h / 7g) | ✅ completata |
| 2 | Elenco progetti VS Code + switch rapido | ✅ completata |
| 3 | Stato Claude Code per progetto via hook | ✅ completata |
| 4 | Due superfici (pannello / notch) + temi | ✅ completata |
| 5 | Distribuzione: DMG, onboarding, auto-update | ✅ completata |

## Build ed esecuzione

```bash
./build.sh                      # → build/Claude Live.app
./build.sh release --install    # → /Applications/Claude Live.app
./run.sh release --install      # build + riavvio + lancio
```

Per pacchettizzare e distribuire vedi la **Fase 5** più sotto.

SwiftPM non produce bundle `.app`, e `LSUIElement`, le notifiche, l'ACL del
Keychain e Sparkle ne richiedono uno: `build.sh` compila l'eseguibile e assembla
il bundle a mano. Versione e feed degli aggiornamenti vengono iniettati in
`Info.plist` da `VERSION` e `release.conf`, così sono dichiarati una volta sola.

### Permessi macOS

L'app **non richiede né Accessibilità né Automazione**: la lista progetti viene
dalla CLI di VS Code (vedi Fase 2). Restano solo due autorizzazioni:

- **Keychain** — al primo avvio macOS chiede l'accesso alla voce
  `Claude Code-credentials`. Con la firma ad-hoc il code hash cambia a ogni
  rebuild, quindi «Consenti sempre» non sopravvive ai rebuild.
- **Notifiche** — richieste al primo avvio, opzionali.

Per evitare la richiesta Keychain a ogni rebuild serve una **identità di firma
stabile**. Con la firma ad-hoc il requisito designato è `cdhash H"…"`, che cambia
a ogni compilazione; con una identità diventa
`identifier "it.aldeialab.ClaudeLive" and certificate leaf = H"…"`, stabile.

Crea il certificato in Accesso Portachiavi → *Assistente Certificati* → **Crea un
certificato…** → *Primo livello autofirmato*, tipo **Firma codice**. Il
certificato risulterà `CSSMERR_TP_NOT_TRUSTED` e non comparirà in
`security find-identity -v -p codesigning`: **è normale e non è un problema**,
l'attendibilità serve alla verifica, non alla firma.

L'identità è dichiarata in **`release.conf`** (`SIGN_IDENTITY`); una variabile
d'ambiente con lo stesso nome ha la precedenza:

```bash
SIGN_IDENTITY="Altra identità" ./build.sh
```

`--install` mette l'app in `/Applications`, un percorso stabile — necessario anche
perché `SMAppService` possa registrare l'avvio al login. Il certificato scade il
**31/07/2027**: alla scadenza va rigenerato, e un certificato nuovo cambia il
requisito di firma (i destinatari dovranno riautorizzare l'app).

## Come funziona la Fase 1

**Token** — letto in sola lettura dal Keychain: voce generic-password con service
`Claude Code-credentials` (più le varianti `Claude Code-credentials-<hash>` come fallback),
il cui payload è JSON:

```json
{ "claudeAiOauth": { "accessToken": "sk-ant-oat01-…", "expiresAt": 1785508744214,
                     "subscriptionType": "team", "rateLimitTier": "default_claude_max_5x" },
  "organizationUuid": "…" }
```

La lettura avviene **fuori dal main thread**, e non è un dettaglio di stile:
`SecItemCopyMatching` blocca il thread chiamante per tutto il tempo in cui macOS
mostra il dialogo «consenti l'accesso a questa voce del Keychain?» — cioè al
primo avvio e dopo ogni rebuild che cambia la firma. Farlo sul main thread
congela l'intera app: timer, file watcher, pannello, tutto. È già capitato una
volta; il sintomo era un'app apparentemente viva ma completamente muta.

L'app **non scrive mai** nel Keychain e **non chiama l'endpoint di refresh OAuth**:
un refresh ruota il refresh token e invaliderebbe la copia usata da Claude Code,
rompendo il login della CLI. Se l'access token è scaduto l'app lo segnala e rilegge
il Keychain al giro successivo — Claude Code lo rinnova da sé al prossimo utilizzo.

**Sonda** — ogni N minuti (default 5) una `POST /v1/messages` con `max_tokens: 1` su
`claude-haiku-4-5`. Tre dettagli sono obbligatori perché un token OAuth di Claude Code
venga accettato (verificati empiricamente; togliendone uno l'API risponde 401):

1. `Authorization: Bearer <token>` — non `x-api-key`
2. `anthropic-beta: oauth-2025-04-20`
3. il system prompt di Claude Code come primo blocco `system`

**Header letti** (verificati su risposta reale):

```text
anthropic-ratelimit-unified-5h-utilization: 0.20    ← frazione 0–1
anthropic-ratelimit-unified-5h-reset: 1785498000    ← unix seconds
anthropic-ratelimit-unified-5h-status: allowed
anthropic-ratelimit-unified-7d-utilization: 0.18
anthropic-ratelimit-unified-7d-reset: 1785740400
anthropic-ratelimit-unified-representative-claim: five_hour
```

Un **429 è trattato come dato valido**, non come errore: la risposta porta comunque
gli header di utilizzo, che è tutto ciò che ci serve.

## Come funziona la Fase 2

**Perché non l'API Accessibility.** Era l'approccio iniziale, ed è stato scartato
su base empirica: VS Code usa una title bar **custom**, quindi il titolo nativo
delle finestre non viene aggiornato e ad AX ogni finestra risulta `"Code"`.
Il nome del progetto semplicemente non è nell'albero AX. Verificato nei log:

```text
[projects] Titolo non risolto: «Code»   ×3
```

**Fonte usata: la CLI di VS Code.** `code --status` lo chiede al processo
principale di VS Code:

```text
Workspace Stats:
|  Window (progetto-alfa)
|  Window (hub-claude)
|  Window (progetto-beta)
```

Due prezzi da pagare, ed entrambi vincolano la frequenza:

1. la chiamata dura **~1,6 s** (VS Code calcola anche le statistiche dei file);
2. la CLI **registra una seconda istanza di VS Code** in LaunchServices → per un
   istante compare un'icona nel Dock. È un problema di UX, non solo di costo.

In cambio la feature **non richiede alcun permesso macOS**: né Accessibilità né
Automazione.

**Aggiornamento: solo su eventi, mai su timer veloce.**

- FSEvents su `workspaceStorage` (VS Code lo tocca quando apre una finestra) →
  rilevamento quasi immediato di un progetto appena aperto;
- avvio / chiusura **reale** di VS Code;
- refresh manuale (menu, o il pulsante ↻ del pannello);
- refresh periodico **opzionale**, default disattivato.

L'attivazione dell'app non è un trigger: causerebbe un lampeggio ogni volta che
passi a VS Code.

**Il loop di feedback da evitare.** Il nostro spawn della CLI genera
`didLaunchApplicationNotification` / `didTerminateApplicationNotification` per il
bundle id di VS Code. Trattandoli come segnali di cambiamento, l'app si
aggiornava all'infinito lanciando una CLI ogni due secondi. La difesa è una
finestra temporale di 6 s attorno a ogni nostra chiamata: il solo confronto dei
pid non basterebbe, perché il pid che otteniamo è quello dello script `code`
mentre chi si registra è il suo figlio Electron, con pid diverso.

Le chiamate sono inoltre coalizzate con un minimo di 4 s, così una raffica di
trigger non accoda più sottoprocessi da 1,6 s.

**Path dei progetti** — `code --status` dà solo il nome; il path completo arriva da
`workspaceStorage/<hash>/workspace.json` (`{"folder": "file:///…"}`). Serve per
associare gli hook della Fase 3 alla riga giusta. Un nome non presente nel
catalogo resta visibile ma non cliccabile (badge `?`).

**Ordinamento** — per recenza d'uso (mtime della cartella workspaceStorage), che
approssima l'ordine con cui li hai usati.

**Focus** — `code "<path>"` seleziona la finestra giusta dentro VS Code ma **non
porta l'app in primo piano** (verificato: l'app frontale non cambiava), quindi va
abbinato a `NSRunningApplication.activate()`.

**Non disponibili** con questo approccio: z-order live e indicatore di finestra
minimizzata (li dava solo AX).

## Come funziona la Fase 3

**Hook.** `Resources/install-claude-hooks.py` installa in `~/.claude/settings.json`
un hook per evento, ognuno che invoca `~/.claude-hub/bin/claude-hub-status.py <stato>`:

| Evento | Stato scritto | Note |
| --- | --- | --- |
| `SessionStart` | `idle` | sessione aperta |
| `UserPromptSubmit` | `working` | hai inviato un prompt |
| `PreToolUse` | `working` | heartbeat + nome del tool; `async: true` |
| `PermissionRequest` | `waiting_input` | il payload porta il nome del tool |
| `Notification` | `waiting_input` | Claude chiede qualcosa |
| `Stop` | `idle` | turno finito |
| `StopFailure` | `error` | turno morto su errore API |
| `SessionEnd` | — | cancella il file di stato |

`PostToolUse` è volutamente **escluso**: raddoppierebbe le scritture senza dire
nulla di nuovo, dato che `working` persiste fino a `Stop`.

**Un file per sessione**, non per progetto: due sessioni possono girare nello
stesso progetto (terminale integrato + terminale esterno) e con un file ciascuna
nessun processo fa read-modify-write sullo stesso file — zero race. L'app le
raggruppa per `project_path` e mostra lo stato **più urgente**
(`waiting_input` > `error` > `working` > `idle` > `unknown`).

**Scritture atomiche** (`tempfile` + `os.replace`) così l'app non legge mai un
file a metà. L'hook non fallisce mai in modo rumoroso: ogni percorso d'errore
esce con 0, perché un hook di stato non deve mai disturbare la sessione che osserva.

**Radice di progetto.** `claude` viene spesso lanciato da una sottocartella, che
altrimenti comparirebbe come progetto a sé. L'hook risale al root git, **escludendo
home e root del filesystem** (`~/.claude` e `~/.git` esistono su molte macchine e
si mangerebbero ogni progetto). Per i progetti non-git ci pensa l'app, riconducendo
il path al workspace VS Code più profondo che lo contiene — informazione che
l'hook non può avere.

**Watcher.** FSEvents con `kFSEventStreamCreateFlagFileEvents` su
`~/.claude-hub/status/`. Un vnode `DispatchSource` sulla directory non
basterebbe: scrivere dentro un file non modifica la directory, quindi gli
aggiornamenti di contenuto sarebbero persi. Un ticker a 15 s copre l'unica cosa
che non è un evento del filesystem: il passare del tempo.

**Stato "stale".** Un record `working` (o `waiting_input`) non aggiornato da oltre
10 minuti diventa `unknown`: la sessione è probabilmente morta senza emettere
`Stop` (crash, terminale chiuso, force quit). I file più vecchi di 24 h vengono
cancellati.

**Idempotenza dell'installer.** Ogni voce che scriviamo contiene
`claude-hub-status.py`; una nuova esecuzione rimuove solo le proprie e le
riscrive. Verificato con hook di terze parti presenti (uno catch-all su `Stop`,
uno con `matcher: "Bash"` su `PreToolUse`): sopravvivono entrambi, insieme a
`permissions` e `effortLevel`. Backup prima di ogni scrittura, output rivalidato
con un re-parse.

```bash
Resources/install-claude-hooks.py              # installa / aggiorna
Resources/install-claude-hooks.py --dry-run    # mostra il risultato, non scrive
Resources/install-claude-hooks.py --uninstall  # rimuove solo i nostri hook
```

## Come funziona la Fase 4

Due superfici alternative, una sola attiva per volta, entrambe che ospitano **le
stesse view SwiftUI** (`UsageSectionView`, `ProjectsSectionView`): è il motivo per
cui la seconda superficie è costata poco.

### Pannello flottante

Trascinabile, con tema **Come il sistema / Chiaro / Scuro**. Il tema è applicato
all'`NSWindow` (`appearance`), non alla view: `NSVisualEffectView` prende il
materiale dall'appearance della finestra, quindi forzando solo il `colorScheme`
di SwiftUI si otterrebbe testo chiaro su sfondo chiaro.

### Notch

Geometria ricavata da `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
(più precise di `safeAreaInsets.top`, che è non-zero anche in alcune
configurazioni esterne). Misurato su questa macchina:

```text
Built-in Retina Display 1512×982 @ 543,-982
auxTopLeft  543 … 1208     auxTopRight 1393 … 2055
→ notch 185×32pt, x 1208 … 1393
```

Il notch **non è necessariamente sullo schermo principale**: qui il principale è
un BenQ esterno.

- **Finestra** a `level = .statusBar` (25), l'unico livello che disegna sopra la
  barra dei menu (`.mainMenu` = 24). `collectionBehavior` include `.stationary`
  così Mission Control non la trascina, e `hasShadow = false` perché un'ombra
  rivelerebbe che è una finestra e non parte del notch.
- **Sempre nera e opaca**: qualsiasi translucenza romperebbe l'illusione di
  continuità col ritaglio fisico.
- **Collassata**: strisce simmetriche da 62pt che abbracciano il notch, per un
  totale di 309pt. I controlli stanno sui bordi esterni e gli anelli abbracciano
  il notch, così i due lati si specchiano: `[⌄][5h◯]` notch `[◯7g][cartella]`.
- **Utilizzo come anello** invece di `5h 11%`: la percentuale esatta vive solo nel
  pannello espanso (e nel tooltip). È ciò che permette strisce da 62pt anziché
  130pt — con il testo la superficie diventava larga 445pt.
- **Espansione**: cambia **solo l'altezza**. Larghezza fissa, così le due
  percentuali restano esattamente dove sono e il pannello legge come il notch che
  si allunga, non come una finestra che compare.
- **Fallback**: senza schermo con notch (o a coperchio chiuso) la modalità non è
  offerta e l'app torna al pannello flottante — mai lasciata senza superficie.
  `didChangeScreenParametersNotification` rivaluta a ogni cambio display.

## Come funziona la Fase 5

Per l'installazione lato utente vedi **[INSTALL.md](INSTALL.md)** — è il documento
da mandare a chi riceve l'app.

### Rilasciare una versione

```bash
# 1. aggiorna la versione e le note
echo "0.2.0" > VERSION
$EDITOR RELEASE_NOTES.md

# 2. prova senza pubblicare
./release.sh --dry-run

# 3. pubblica
./release.sh
```

`release.sh` costruisce il DMG, lo firma con la chiave EdDSA di Sparkle, crea la
release su GitHub e **solo alla fine** aggiorna l'appcast: se un passaggio prima
fallisce, nessun client viene puntato su un download inesistente. L'appcast viene
riscritto da un clone fresco del repo, così una copia locale vecchia non può
cancellare voci pubblicate da un'altra macchina.

### Aggiornamenti automatici (Sparkle)

Sparkle arriva come XCFramework via SwiftPM: `swift build` lo collega ma non lo
incorpora, quindi `build.sh` lo copia in `Contents/Frameworks/` e il binario porta
un rpath `@executable_path/../Frameworks` (vedi `Package.swift`).

Due trappole incontrate, entrambe risolte:

1. **La firma va fatta dall'interno verso l'esterno.** Gli XPC services e
   l'updater di Sparkle sono codice annidato: se si firma prima il contenitore,
   la firma esterna sigilla un framework non firmato e macOS rifiuta il bundle.
2. **Niente `--options runtime`.** L'hardened runtime attiva la *library
   validation*, che pretende lo stesso Team ID fra binario e librerie caricate.
   Un certificato self-signed non ha Team ID, quindi `dyld` rifiutava il
   framework con *«mapping process and mapped file (non-platform) have different
   Team IDs»* e l'app moriva all'avvio. L'hardened runtime serve solo alla
   notarizzazione, che qui non facciamo; se in futuro si adotta un vero
   Developer ID va rimesso, e allora la library validation passa da sé perché
   app e framework condividono il Team ID.

**La chiave privata di Sparkle è nel Keychain** (voce *Private key for signing
Sparkle updates*). Va salvata da parte: senza di essa **le copie già installate
non possono più essere aggiornate**, perché rifiutano qualsiasi pacchetto che non
verifichi contro la chiave pubblica compilata dentro l'app. Per esportarla:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x chiave-sparkle.txt
# conservala offline, poi elimina il file dal disco
```

### Firma e Gatekeeper

L'app è firmata con un certificato **self-signed**, quindi al primo avvio ogni
destinatario deve autorizzarla da Impostazioni di Sistema → Privacy e Sicurezza →
*Apri comunque*. Da macOS 15 il vecchio "clic destro → Apri" non basta più.

Il certificato scade il **31/07/2027**: alla scadenza va rigenerato, e un
certificato nuovo cambia il requisito di firma — i destinatari dovranno
riautorizzare l'app e riconcedere l'accesso al Keychain.

Con un Apple Developer Program (99€/anno) tutto questo sparisce: firma
*Developer ID* + notarizzazione = doppio clic e via.

## File su disco

```text
~/Library/Application Support/ClaudeHub/
├── settings.json          # configurazione
├── usage-cache.json       # ultimo snapshot (mostrato all'avvio, marcato come vecchio)
└── logs/claudelive.log    # solo con log di debug attivo
```

```text
~/.claude-hub/
├── bin/claude-hub-status.py       # hook installato
└── status/<hash>.<session>.json   # uno per sessione Claude Code
```

## Architettura

```text
Sources/ClaudeLive/
├── main.swift                  bootstrap NSApplication
├── App/AppDelegate.swift       composizione delle dipendenze
├── Core/                       Paths, Log, Settings, Formatters, DirectoryWatcher
├── Usage/                      Credentials, UsageModels, UsageAPIClient, UsageMonitor
├── Projects/                   EditorApp, VSCodeCLI, WorkspaceCatalog, ProjectsMonitor
├── ClaudeStatus/               ClaudeSessionStatus, ClaudeStatusStore, HookInstaller
├── Notifications/              UsageNotifier, WaitingInputNotifier
├── MenuBar/                    MenuBarController
├── PanelUI/                    FloatingPanel (AppKit) + PanelController + viste SwiftUI
└── Settings/                   finestra impostazioni
```

Le viste in `PanelUI` non toccano AppKit e ricevono i comandi tramite `PanelActions`:
è quello che permetterà di riusare `PanelRootView` nella futura modalità notch,
sostituendo solo `FloatingPanel`/`PanelController`.
