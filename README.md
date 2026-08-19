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
  `Claude Code-credentials`.
- **Notifiche** — richieste al primo avvio, opzionali. Il suono si sceglie tra
  quelli di macOS (Impostazioni → Notifiche): il nome del file viene passato a
  `UNNotificationSound`, che lo risolve nelle stesse cartelle di `NSSound` —
  niente da copiare nel bundle — e un nome che non esiste più torna al suono di
  sistema invece di produrre una notifica muta. Il pulsante «Prova» manda una
  notifica **vera** e non riproduce il file: è l'unico modo di sentire quel che si
  sentirà davvero.

  Una notifica che arriva mentre Claude Live è l'app **attiva** viene scartata da
  macOS in silenzio — nessun banner, nessun suono, nessun errore — se il delegate
  non implementa `willPresent`. Per un'app della barra dei menu il caso è raro e
  quindi resta invisibile a lungo: si è manifestato dalla finestra delle
  impostazioni, l'unico posto da cui l'app è in primo piano quando posta qualcosa,
  con un pulsante «Prova» che non faceva nulla. `CLAUDELIVE_TEST_NOTIFICATION=1`
  riproduce esattamente quel caso — posta l'anteprima con l'app portata in primo
  piano — e registra nel log cosa ha in mano il centro notifiche, perché
  «non è successo niente» da solo non distingue *non autorizzato* da *suono
  inesistente* da *scartata*.

Perché «Consenti sempre» sul Keychain non venga chiesto di nuovo a ogni rebuild
serve una **identità di firma stabile**: con la firma ad-hoc il requisito
designato è `cdhash H"…"`, che cambia a ogni compilazione, mentre con una
identità diventa `identifier "it.aldeialab.ClaudeLive" and certificate leaf = H"…"`,
che non cambia.

L'identità usata è **Developer ID Application**, dall'Apple Developer Program.
Creala una volta in Xcode → *Settings* → *Accounts* → seleziona l'Apple ID →
**Manage Certificates** → **+** → *Developer ID Application*, poi copia la
stringa esatta che compare in:

```bash
security find-identity -v -p codesigning
```

Serve anche un profilo di credenziali per la notarizzazione (una volta sola;
richiede una *app-specific password* generata su appleid.apple.com, perché
`notarytool` rifiuta la password normale dell'Apple ID):

```bash
xcrun notarytool store-credentials "claude-live-notary" \
  --apple-id "…" --team-id "…" --password "…"
```

Entrambi sono dichiarati in **`release.conf`** (`SIGN_IDENTITY`, `TEAM_ID`,
`NOTARY_PROFILE`); una variabile d'ambiente `SIGN_IDENTITY` ha la precedenza:

```bash
SIGN_IDENTITY="Altra identità" ./build.sh
```

`build.sh` decide come firmare in base al prefisso dell'identità: con
`Developer ID Application:` aggiunge hardened runtime e timestamp sicuro
(obbligatori per la notarizzazione), con qualsiasi altra identità non lo fa —
vedi la trappola della *library validation* nella Fase 5.

`--install` mette l'app in `/Applications`, un percorso stabile — necessario anche
perché `SMAppService` possa registrare l'avvio al login.

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

### Token, cache e stati (le trappole)

Tre bug distinti, tutti osservati nello stesso log notturno, tutti facili da
reintrodurre:

1. **Non rifiutare mai di provare per colpa dell'orologio locale.** La versione
   precedente scartava il token se `expiresAt` era passato (con 5 minuti di slack).
   Risultato misurato: alle 09:44 ha rifiutato un token valido per altri 4 minuti,
   poi è rimasta muta fino alle 10:14 — 7 letture del portachiavi, **zero richieste**
   — finché Claude Code non ha rinnovato. Se un token funziona lo decide il server.
   L'unico token che non si riprova è quello che l'**API** ha già rifiutato
   (`rejectedToken`), e basta che Claude Code ne scriva un altro perché si riparta.
2. **Un dialogo del portachiavi senza risposta bloccava tutto il ciclo.**
   `SecItemCopyMatching` blocca il thread per quanto resta aperto il suo dialogo:
   misurati **55 minuti**, con `inFlight` a true e dieci poll consecutivi saltati
   («già in corso»). Ora l'attesa ha un timeout di 20s, la lettura in corso è
   condivisa (mai due dialoghi in coda) e il suo risultato viene raccolto anche se
   arriva dopo il timeout.
3. **In dark wake il Mac si sveglia e il portachiavi non può mostrare UI.** Cinque
   errori «In dark wake, no UI possible» in una notte, ognuno dei quali sostituiva i
   numeri con un messaggio d'errore. I poll automatici ora si fermano se lo schermo
   è spento (`CGDisplayIsAsleep`); quelli chiesti dall'utente no.

**La cache delle credenziali è indicizzata sulla data di modifica dell'item**, non
sulla scadenza del token. Una query **solo attributi** non decifra niente, quindi non
consulta la ACL e non può far comparire il dialogo: misurato **8ms contro 3681ms**
della lettura del payload, da un binario non firmato e senza alcuna autorizzazione.
Quindi il payload si legge una volta per rinnovo (~8h) invece di una volta per poll —
ed è anche la fine dei «chiede la password ogni due minuti».

Infine: `isStale` sbiadisce le barre al 45%, e **da solo** comunica che qualcosa non
va senza dire cosa — un utente l'ha letto come «l'app si è spenta». Il motivo era già
disponibile in `monitor.state`, mancava solo in schermo: ora `UsageSectionView` mostra
una riga arancione con la causa.

`CLAUDELIVE_FORCE_BAD_TOKEN=1` corrompe il token prima della richiesta, per provare il
percorso 401 senza aspettare otto ore.

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
|  Window (Costruire app macOS Sipp… — progetto-alfa)
|  Window (Claude Live: macOS menu … — hub-claude)
|  Window (Fix scrolling, notificat… — progetto-beta)
```

**Fra parentesi c'è il titolo della finestra, non il nome della cartella.** Il
titolo di default è `${activeEditorShort}${separator}${rootName}`, quindi *sembra*
un nome di progetto solo quando nessuna tab è attiva — ed è esattamente così che
l'ho letto male la prima volta: le finestre erano senza tab attiva e ho concluso
che quel campo fosse il nome del progetto. Con una sessione Claude Code nel
terminale integrato il titolo diventa `<tab> — <progetto>` e non combacia più con
nulla: le righe restavano visibili ma non cliccabili, con badge `?`.

La risoluzione non si fida della posizione nel titolo (`window.title` è
configurabile, e il formato è già cambiato una volta sotto le nostre mani): cerca
il componente che corrisponde a un workspace **già noto** in `workspaceStorage`,
scandendo dalla fine. Se nulla combacia ripiega sull'ultimo componente.

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

**Stato e avviso sono cose diverse**, e la differenza è il punto. Lo stato
(`ClaudeActivity`) è ciò che una sessione sta facendo *adesso*, ricalcolato dal
disco ogni pochi secondi. Un avviso (`ClaudeAlert`) è un **evento**: lo alza una
transizione, sopravvive allo stato che l'ha causato, e se ne va quando l'utente
l'ha visto — che è ciò che deve fare un segnale di notifica. «Claude ha finito»
come stato non esiste: una sessione che ha finito e una appena aperta sono
entrambe `idle`, e solo la prima ci arriva da `working`.

| Transizione | Avviso |
| --- | --- |
| → `waiting_input` | chiede qualcosa |
| `working`/`waiting_input` → `idle` | ha finito |
| → `error` | si è interrotto |
| `working` → `unknown` (silenzio da 10 min) | si è interrotto |
| → `working` | azzera l'avviso: il turno nuovo rende moot quello vecchio |

L'avviso si azzera anche quando il file di stato scompare, perché la riga di
progetto che lo spegnerebbe può essere sparita con lui: una luce che nessuno può
spegnere è peggio di una mancata.

**Spegnerlo entrando nel progetto** (`FrontProjectWatcher`) costa un permesso, e
il perché è istruttivo: sapere *quale* finestra dell'editor è davanti significa
leggerne il **titolo**, e macOS lo protegge — `CGWindowListCopyWindowInfo` lo omette
senza Registrazione Schermo, l'API di Accessibilità lo nega senza il proprio
permesso. Senza uno dei due l'app può sapere solo «un editor è in primo piano», non
quale progetto mostri. Quindi due livelli, e nessuno dei due è una bugia all'utente:
col permesso di Accessibilità il titolo viene risolto in progetto attraverso lo
stesso catalogo della lista progetti, quindi si spegne esattamente quell'avviso e
funziona anche passando da una finestra all'altra; senza permesso, un editor che
arriva in primo piano azzera l'avviso solo se ce n'è **uno solo** — e solo su un
vero cambio di applicazione, non sul polling, altrimenti un avviso alzato mentre eri
già nell'editor si spegnerebbe prima che tu lo veda. `AXUIElementSetMessagingTimeout`
è a 0,25s perché il thread principale non resti in ostaggio di un editor occupato a
indicizzare.

**Una sessione è una chat.** Il riassunto per progetto (`statusesByPath`) resta,
ma accanto vive l'elenco completo (`sessionsByPath`): la riga del progetto porta
quante chat sono aperte e, quando sono più di una, le elenca sotto — una riga per
chat con il suo stato e da quanto non si aggiorna. Il riassunto è **derivato** da
quell'elenco, non cercato a parte, così i due non possono discordare: prima un
progetto con una sessione sulla radice e una in una sottocartella prendeva il
riassunto dal solo gruppo della radice, e una sottocartella in attesa di risposta
finiva contata nell'elenco e assente dal pallino. Ogni chat è etichettata con la
sottocartella da cui è partita (`cwd`) quando differisce dalla radice, altrimenti
con l'inizio del `session_id`: è tutto quel che l'hook sa dire di riconoscibile.

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

Cambiare superficie **non** è nascondere il pannello: `PanelController.suspend()`
lo toglie dallo schermo senza toccare `panelVisible`, mentre `hide()` registra
l'intenzione dell'utente. Il bug che questa distinzione risolve: passare al notch
chiamava `hide()`, quindi tornando al pannello flottante non compariva più nulla e
bisognava richiamarlo dal menu. Per lo stesso motivo `applyDisplayMode(isInitial:)`
distingue «ripristina cosa c'era» all'avvio da «l'utente ha scelto questa
superficie», che è una richiesta di vederla.

**L'icona in barra è opzionale** (`showMenuBarIcon`), e questo impone un vincolo
al resto: tutto ciò che si può fare dal menu deve essere possibile anche dalle
impostazioni, che si aprono dalla rotella nel pannello. `NSStatusItem.isVisible`
invece di rimuovere l'item, perché l'item è il proprietario del menu e distruggerlo
significherebbe ricostruire tutto per far ricomparire l'icona.

Il vincolo scomodo è la raggiungibilità: con l'icona nascosta *e* il pannello
flottante nascosto non resterebbe niente da cliccare, e lo stato è persistito —
quindi un riavvio ripartirebbe altrettanto irraggiungibile, con l'unico rimedio di
modificare `settings.json` a mano. Due difese, nessuna delle quali vieta la
combinazione: `applicationShouldHandleReopen` apre le impostazioni (riaprire l'app
dal Finder è il gesto che funziona sempre), e `ensureReachable()` riaccende l'icona
se nessuna superficie è visibile — a cedere è l'impostazione spenta per ordine, non
quella in uso.

Il menu della barra è riempito in `menuNeedsUpdate`, cioè nell'istante prima di
aprirsi, non ricostruito a ogni cambiamento: è ciò che tiene aggiornati l'elenco
dei monitor collegati e le voci che dipendono dalla modalità (`Schermi notch` col
notch, `Posizione pannello` col pannello) ed evita di sostituire
`statusItem.menu` mentre è aperto sotto il cursore. `MenuBarController.logStructure()`
lo scrive nel log, unico modo di verificarlo senza pilotare la UI.

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
Built-in Retina Display 1512×982 @ 0,0
auxTopLeft  0 … 665     auxTopRight 850 … 1512
→ cutout 185×32pt, x 665 … 850
```

Il notch **non è necessariamente sullo schermo principale**: qui il principale è
un monitor esterno.

- **Finestra** a `level = .statusBar` (25), l'unico livello che disegna sopra la
  barra dei menu (`.mainMenu` = 24). `collectionBehavior` include `.stationary`
  così Mission Control non la trascina, e `hasShadow = false` perché un'ombra
  rivelerebbe che è una finestra e non parte del notch.
- **Scrivanie**: `.canJoinAllSpaces` non è retroattivo — mette la finestra sulle
  scrivanie che esistono quando viene ordinata in primo piano, e una **creata
  dopo** non la riceve mai. Su quella scrivania la finestra non è affatto
  «appiccicata»: resta agganciata a quella di partenza e scorre via con essa, che
  è esattamente l'aspetto di «il notch segue la scrivania invece di stare fermo».
  Il rimedio è riordinarla in primo piano a ogni
  `NSWorkspace.activeSpaceDidChangeNotification`
  (`NotchWindow.reassertSpacePresence`, e lo stesso per `FloatingPanel`): la prima
  visita a una scrivania nuova la aggancia, dalle successive resta ferma.
- **Sempre nera e opaca**: qualsiasi translucenza romperebbe l'illusione di
  continuità col ritaglio fisico.
- **Collassata**: strisce simmetriche che abbracciano il cutout — `[⌄][5h◯]`
  cutout `[◯7g][cartella]` — per un totale di 339pt a scala 1. I controlli stanno
  sui bordi esterni e gli anelli abbracciano il cutout, così i due lati si
  specchiano.
- **Controlli opzionali**: `notchShowsControls` (Impostazioni → Superficie) toglie
  chevron e pulsante progetti, e la barra si **restringe** con loro invece di
  lasciare due slot di nero vuoti — 291pt a scala 1. Restano gli anelli, che erano
  già anche il modo di aprire il pannello. Con nessuna
  freccia da premere due volte, chiudere cliccando **fuori** dal pannello diventa
  necessario: due monitor di eventi mouse, uno globale (i clic nelle altre app,
  mai le nostre) e uno locale (le nostre finestre, mai le altrui), e in entrambi i
  casi il clic viene lasciato passare. Gli eventi del mouse non richiedono
  permessi, a differenza di quelli da tastiera.
- **Utilizzo come anello** invece di `5h 11%`: la percentuale esatta vive solo nel
  pannello espanso (e nel tooltip). È ciò che tiene la superficie a 339pt: con il
  testo diventava larga 445pt.
- **Segnale luminoso** (`NotchGlowView`): una striscia neon lungo il contorno,
  che pulsa dal centro verso le estremità e torna. Sta nella finestra dell'aura,
  **dietro** al notch, e il tratto è disegnato largo circa il doppio di quel che si
  vede: il nero del pannello copre la metà interna, quindi è l'occlusione a fare da
  maschera e resta una striscia che abbraccia il bordo da fuori. Niente da
  ritagliare a mano, e la luce non può finire sopra il contenuto del pannello.
  Il movimento non è un'animazione da sincronizzare con nulla: la luminosità è una
  funzione della posizione orizzontale — una banda gaussiana centrata sulla distanza
  `fase` dal centro — quindi **un solo gradiente** disegna entrambe le bande e la
  simmetria è gratis. Sotto resta un filo acceso al 16%, che è ciò che la fa leggere
  come una striscia con la luce che ci scorre dentro invece che come due puntini che
  si inseguono. Le palette (`GlowStyle`) sono simmetriche per lo stesso motivo: un
  arcobaleno da sinistra a destra metterebbe un colore diverso sotto ciascuna delle
  due bande. `NotchGlowFilmstrip` ne scrive i fotogrammi su file, perché è
  un'animazione su una finestra sopra la barra dei menu e `screencapture` richiede
  il permesso di Registrazione Schermo.
- **Ombra**: solo da espanso, in dissolvenza sulla stessa durata dell'apertura.
  Vive in una **finestra a parte** dietro a questa, perché la finestra del notch è
  grande esattamente quanto ciò che dipinge — l'invariante che le impedisce di
  rubare clic — e un'ombra ha bisogno di spazio *fuori* dalla forma. Le alternative
  sono entrambe già state provate: allargare la finestra del notch riporta il bug
  del margine trasparente, e `hasShadow` sulla finestra si accende e si spegne di
  colpo, che è esattamente ciò che qui non si vuole. La finestra dell'ombra ha
  `ignoresMouseEvents = true`, l'unico modo in cui una finestra trasparente più
  grande del suo contenuto non può intercettare nulla: l'evento non viene scartato,
  non ci viene mai offerto. Dentro non c'è nessun nero duplicato da tenere in
  sincrono — un `CALayer` con `shadowPath` disegna la sua ombra qualunque sia il
  contenuto, quindi il layer è del tutto trasparente e casta comunque. Path e frame
  vengono aggiornati nello stesso giro di run loop del frame del notch, così
  l'ombra non resta indietro di un fotogramma.
- **Ordine del contenuto fisso**: utilizzo, poi progetti, da qualunque comando si
  apra. Dipendeva dal comando — il pulsante progetti metteva la lista prima, il
  chevron la metteva dopo — quindi lo stesso pannello aveva due disposizioni e non
  c'era modo di imparare dov'erano le cose. Ora coincide anche col pannello
  flottante, che ospita queste stesse view.
- **Espansione**: cresce in altezza **e** in larghezza (fino a 624pt), con un
  piccolo rimbalzo. Le strisce restano ancorate al cutout e la larghezza in più
  compare come nero attorno — vedi `NotchSurface` per chi possiede l'animazione e
  per i due approcci che hanno fallito prima di questo.

#### Smusso ai lati (`NotchShape`)

I due angoli superiori sono **concavi**, non retti:

```text
 ┌──╮                    ╭──┐   ← al bordo dello schermo la forma è a
 │  ╰────────────────────╯  │     larghezza piena
 │   striscia cutout striscia │
 ╰──────────────────────────╯   ← angoli inferiori convessi
```

Un angolo a 90° annuncia «questa è una finestra appoggiata sulla barra dei menu»;
il raccordo concavo si legge come il notch stesso che si allarga. Conseguenza per
il layout: il **corpo** nero è rientrato di `flareRadius` (12pt) per lato, quindi
la finestra è larga `corpo + 24pt` e il contenuto va rientrato di altrettanto.
Tutto ciò che deriva da `NotchGeometry` ne tiene già conto.

#### Distribuzione dentro la striscia

`stripWidth = controlSlot (32) + ringInset (7) + ringDiameter`, senza spazio non
assegnato — e `ringOuterPad (8)` al posto dello slot quando i controlli sono
nascosti, solo perché un anello a filo del bordo nero si legge come un errore di
disegno. Il controllo esterno — chevron a sinistra, pulsante progetti a destra —
sta in uno **slot a larghezza fissa** ed è centrato dentro quello slot; l'anello
abbraccia il cutout.

Prima c'era uno `Spacer`, e uno spacer mette tutto lo slack da un lato solo: il
chevron finiva schiacciato contro l'anello con un buco visibile al bordo esterno, e
il pulsante progetti restava scentrato in quel che rimaneva. Misurato sullo snapshot
reale: chevron centrato a 15,5pt dal bordo del corpo, progetti a 16,5pt dall'altro —
speculari.

#### Dimensione del notch

Impostazioni → Superficie → **Scelta schermi e dimensioni notch** apre
`NotchScreensView`: le anteprime degli schermi come in Impostazioni di sistema →
Monitor, cliccabili per attivare o disattivare il notch, la dimensione dei
contatori — che è una misura della barra come le altre, dato che le strisce sono
larghe quanto l'anello che contengono — e sotto le misure (60…600 ×
24…72pt, default 170×32) **uguali per tutti** oppure **separate per ogni schermo**.

La separazione per schermo non è un vezzo: una barra da 170pt su un pannello da
1512pt è un'altra cosa su un monitor da 1920pt, e prima una misura sola valeva per
tutti.

Nell'anteprima la barra è disegnata con `NotchShape` alla larghezza reale in scala,
così il confronto tra schermi è quello vero. L'**altezza** invece ha un minimo
leggibile: 32pt su uno schermo da 1512 sono 3 punti d'anteprima, un capello che si
legge come un artefatto di rendering e non come una barra. Il minimo di larghezza è
tenuto piccolo (12pt) proprio per non falsare quel confronto.

Gli schermi sono ordinati **da sinistra a destra come stanno fisicamente**
(`frame.minX`), che è come li mostra Impostazioni di sistema e come l'utente
riconosce quale monitor è quale.

La larghezza è quella del tratto centrale; la barra completa aggiunge le due
strisce.

Su uno schermo con il ritaglio fisico le due misure sono **minimi**, non valori
ignorati: sotto la larghezza del buco gli anelli finirebbero *dentro* il ritaglio,
dove non viene visualizzato nulla, e sotto la sua altezza il bordo inferiore del buco
sporgerebbe sotto la barra. Sopra quei minimi la barra cresce normalmente, quindi
l'impostazione funziona su ogni schermo. Il valore effettivo è mostrato accanto allo
slider (`170 → 185 pt`), altrimenti metà corsa sembra non fare nulla.

Due bug da non reintrodurre:

- `geometries(selection:…)` costruiva il ramo *automatico* con un helper che **non
  prendeva la dimensione**, quindi su un Mac col notch fisico larghezza e altezza non
  facevano assolutamente niente. Ora ogni ramo passa da un unico `resolve(_:)`.
- la dimensione richiesta veniva scartata anche perché il ramo fisico ignorava il
  parametro invece di usarlo come minimo.

`ringDiameter` è limitato a `barHeight - 2`: il contenuto è ritagliato dalla finestra,
quindi un anello troppo grande verrebbe *tagliato* e non rimpicciolito. Il limite
morde solo su una barra bassa — a 32pt lascia intatta tutta la corsa dello slider
«Dimensione contatori».

`CLAUDELIVE_SELFTEST=1` verifica la catena impostazione → geometria → finestra
scrivendo nel log il rect reale di ogni superficie a ogni cambio di misura.

#### Su quali schermi

Impostazioni → Superficie → **Schermi**: `Automatico` (quello col cutout, in
mancanza lo schermo principale), `Schermi scelti`, `Tutti gli schermi`.

- Su uno schermo **senza** cutout il notch viene **disegnato**: 170×32pt al centro
  del bordo superiore. Il gap centrale, che su un notch vero è il buco fisico, qui
  è semplicemente nero come il resto — stessa view, nessun ramo in più.
- Gli schermi scelti sono salvati come **UUID del pannello**
  (`CGDisplayCreateUUIDFromDisplayID`), non come `CGDirectDisplayID` (assegnato per
  sessione, cambia riconnettendo in ordine diverso) né come nome (due monitor
  identici tornano come `PHL 241E1 (1)` e `(2)`, e chi prende quale suffisso non è
  stabile). Il nome resta la cosa giusta da **mostrare**.
- Una scelta che non risolve — monitor scollegato, o nessuna scelta fatta — ricade
  sull'automatico: l'app non resta mai senza superficie visibile. Gli UUID dei
  monitor assenti **non** vengono rimossi, così riattaccandoli il notch ricompare
  senza riconfigurare nulla.
- Una superficie per schermo (`NotchSurface`), ognuna con la propria espansione:
  apri quella che stai guardando. L'insieme viene *ricalcolato*, non ricostruito, a
  ogni `didChangeScreenParametersNotification`: una superficie ancora valida viene
  aggiornata sul posto, così attaccando un secondo monitor il notch esistente non
  lampeggia.
- **Fallback**: senza alcuno schermo l'app torna al pannello flottante.

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
2. **`--options runtime` solo con un vero Developer ID.** L'hardened runtime
   attiva la *library validation*, che pretende lo stesso Team ID fra binario e
   librerie caricate. Un certificato self-signed non ha Team ID, quindi `dyld`
   rifiutava il framework con *«mapping process and mapped file (non-platform)
   have different Team IDs»* e l'app moriva all'avvio. Con il Developer ID app e
   framework condividono il Team ID e la library validation passa da sé, quindi
   `build.sh` attiva l'hardened runtime **solo** su quel ramo — è la ragione per
   cui la scelta è condizionata al prefisso dell'identità e non fissa.

   Per lo stesso motivo **non esiste un file di entitlements**: non sandboxata,
   l'app non ne ha bisogno (leggere la voce Keychain di un'altra app dipende
   dalla ACL della voce, e lanciare `code`/`python3` non è qualcosa che
   l'hardened runtime limiti). Dichiarare entitlements «per sicurezza»
   indebolirebbe solo il runtime.

**Verificato end-to-end** (non solo per costruzione): installata la 0.1.0 dal DMG,
pubblicata la 0.1.1, la copia installata l'ha trovata, scaricata, verificata e
installata **riavviandosi da sola**. Nel log:

```text
Sparkle avviato (versione 0.1.0, …)
Appcast caricato: 2 voci
Aggiornamento trovato: 0.1.1
Sparkle avviato (versione 0.1.1, …)
```

L'installazione è silenziosa perché `SUAllowsAutomaticUpdates` è `true`: è ciò che
serve per un'app che deve aggiornarsi senza chiedere nulla. Per farla invece
chiedere prima di installare, metti quella chiave a `false` in `Resources/Info.plist`.

**Attenzione alla cache di `raw.githubusercontent.com`**: serve una copia in cache
per qualche minuto, quindi subito dopo `release.sh` l'appcast può ancora sembrare
quello vecchio. Il repo è già aggiornato — verificalo con
`gh api repos/OWNER/REPO/contents/appcast.xml --jq .content | base64 -d`.
Non è un problema reale: gli aggiornamenti non sono urgenti.

**La chiave privata di Sparkle è nel Keychain** (voce *Private key for signing
Sparkle updates*). Va salvata da parte: senza di essa **le copie già installate
non possono più essere aggiornate**, perché rifiutano qualsiasi pacchetto che non
verifichi contro la chiave pubblica compilata dentro l'app. Per esportarla:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p   # solo la metà pubblica
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x chiave-sparkle.txt
# conservala offline, poi elimina il file dal disco
```

**Per reimportarla su una macchina nuova** serve `-f`, e qui c'è una trappola che
costa tempo. `-x` esporta un file su tre righe — il seme base64, una riga vuota,
poi `Pub <chiave pubblica>` — ma `-f` rifiuta quel formato: vuole un file con **il
solo seme**, su una riga, e la riga `Pub` di troppo lo fa fallire. L'errore è
fuorviante, perché stampa l'intero contenuto del file dopo
«Failed to decode base64 encoded key data»: sembra un problema della chiave,
è la riga in più.

```bash
head -1 chiave-sparkle.txt > solo-seme.txt        # scarta la riga Pub
.build/artifacts/sparkle/Sparkle/bin/generate_keys -f solo-seme.txt
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p   # deve stampare SU_PUBLIC_ED_KEY
rm solo-seme.txt chiave-sparkle.txt
```

L'ultima riga non è pedanteria: se la chiave importata non è quella distribuita,
le firme prodotte sono valide ma **nessuna copia installata le accetta**, perché
verificano contro la pubblica nel proprio `Info.plist`. Per questo il preflight di
`release.sh` confronta `generate_keys -p` con `SU_PUBLIC_ED_KEY` e si rifiuta di
partire se differiscono.

### Firma, notarizzazione e Gatekeeper

L'app è firmata **Developer ID Application** e notarizzata da Apple: i
destinatari fanno doppio clic e l'app si apre, senza passare da Impostazioni di
Sistema → Privacy e Sicurezza → *Apri comunque* (che da macOS 15 è anche l'unica
strada rimasta, perché il vecchio "clic destro → Apri" non basta più).

`package.sh` notarizza **due volte, separatamente**, e non è una ridondanza:

1. **l'app**, prima di infilarla nel DMG, con il ticket poi cucito dentro il
   bundle da `stapler`. Senza questo passaggio l'app trascinata fuori dal DMG non
   porterebbe alcun ticket proprio, e un primo avvio **senza rete** potrebbe
   essere bloccato;
2. **il DMG**, che è il file che l'utente scarica davvero ed è la prima cosa che
   Gatekeeper valuta.

Il verdetto finale viene verificato con `spctl -a -vvv -t install` sul DMG: è la
stessa valutazione che farà la macchina di chi lo riceve, quindi se passa lì
passa anche là.

Attenzione a due cose che restano vere:

- **la notarizzazione non sostituisce la firma EdDSA di Sparkle.** Sono controlli
  diversi: Apple certifica che il binario non è malware, Sparkle verifica che
  l'aggiornamento venga da chi possiede la chiave privata. L'app rifiuta un
  download che non verifichi contro la chiave pubblica nel suo `Info.plist`
  anche se Apple l'ha notarizzato;
- **cambiare certificato cambia il requisito designato.** Passando dal vecchio
  self-signed al Developer ID, chi aveva già l'app installata deve riconcedere
  una volta l'accesso alla voce Keychain. È una tantum, non si ripete agli
  aggiornamenti successivi finché l'identità resta la stessa.

### La richiesta di password del portachiavi, e perché «Sempre» non bastava

Vale la pena sapere com'è fatta la voce `Claude Code-credentials`, perché spiega la
richiesta di password che sembra arrivare a caso. Letta con
`SecAccessCopyACLList` (leggere l'ACL non decifra nulla, quindi non chiede niente):

```text
ACL 0 — Decrypt
  applicazioni autorizzate: /Applications/Claude Live.app
                            /usr/bin/security     ← è così che accede Claude Code
  Partitions: [ apple-tool:, teamid:G7PDRQRC29 ]
```

Due meccanismi, entrambi da soddisfare: la lista di applicazioni è per **percorso**
(30 byte per voce: solo la stringa del path), e la partition list è per **team id**
della firma. Le conseguenze pratiche:

* una copia eseguita da `build/` o dal DMG è un'altra applicazione per il
  portachiavi, e «Consenti sempre» dato a una non vale per l'altra. Durante lo
  sviluppo è la causa di praticamente ogni richiesta di password;
* «Consenti» (una volta) e «Sempre» sono cose diverse: solo il secondo scrive nella
  lista.

Ma il percorso è **metà** della storia, e l'altra metà è quella che conta:
**Claude Code, quando riscrive la voce per rinnovare il token, azzera la lista.**
Misurato — voce riscritta alle 09:47:02, richiesta di password alle 09:48:51 dalla
copia in `/Applications`, la stessa che nove minuti prima aveva letto in silenzio.
L'autorizzazione la distrugge il proprietario della voce, ogni poche ore: nessun
numero di «Sempre» può sopravvivere. `cdat` resta al 3 giugno mentre `mdat` avanza,
quindi la voce non viene ricreata — viene aggiornata, e l'aggiornamento si porta via
l'ACL.

L'unica voce che sopravvive è **`/usr/bin/security`**, perché è lo strumento con cui
Claude Code scrive e ogni scrittura la ri-aggiunge — ed è anche il motivo per cui
Claude Code non si vede mai chiedere nulla. Quindi `readItem` legge **attraverso di
lui** (`security find-generic-password -s … -w`, uscita su pipe, mai su disco, mai
nel log): la richiesta arriva da un'applicazione autorizzata per costruzione, 46 ms
senza finestra, contro gli 80 secondi di attesa di un dialogo con l'API diretta.
L'API diretta resta come ripiego, perché quella voce nell'ACL è un dettaglio
d'implementazione di un altro programma: se un giorno smettesse di esserci, la
lettura funziona ancora — solo, può chiedere.

`CredentialsStore.authorizationState()` interroga tutto questo **senza mai mostrare
una finestra**: `SecKeychainSetUserInteractionAllowed(false)` fa fallire la lettura
con un codice invece di aprire il dialogo. Due codici significano «non autorizzato»
e la differenza si scopre solo provando — `errSecInteractionNotAllowed` è «avrebbe
chiesto», `errSecAuthFailed` è quel che il portachiavi risponde davvero quando il
binario non è nella lista. Il flag è **globale al processo**, quindi la coda del
portachiavi è seriale: una sonda in parallelo a una lettura vera la farebbe fallire
in silenzio, trasformando la diagnostica nella causa del problema che descrive.
Impostazioni → Diagnostica mostra lo stato, e una lettura che dura più di un secondo
viene registrata come «macOS ha chiesto l'autorizzazione» — perché «me l'ha chiesta
di nuovo» altrimenti non è verificabile a posteriori.

### Una sola copia per volta

Due copie accese insieme non sono un caso di scuola: succede appena si prova una
build mentre quella installata è in esecuzione, e il modo in cui si rompono non
somiglia per niente alla causa. Condividono `settings.json` (vince chi salva per
ultimo, e le preferenze sembrano cambiare da sole), raddoppiano le notifiche,
disegnano due notch — e ognuna chiede a VS Code la lista delle finestre con
`code --status`, **senza poter riconoscere la domanda dell'altra**: il filtro
anti-auto-innesco di `ProjectsMonitor` conosce solo i propri spawn, quindi ciascuna
prende quello dell'altra per un avvio vero dell'editor e si aggiorna, per sempre. Il
sintomo osservato è una seconda icona di VS Code che lampeggia nel Dock ogni pochi
secondi, e non suggerisce in alcun modo «hai due copie accese».

`olderRunningInstance()` confronta le **date di avvio** invece di chiedere solo «c'è
qualcun altro con questo bundle id?»: due copie lanciate insieme si vedrebbero a
vicenda e si chiuderebbero entrambe. La più giovane esce con `exit`, non con
`NSApp.terminate`, perché il teardown normale cancella l'heartbeat degli hook — che
appartiene alla copia che resta, e senza il quale Claude Code smette di attendere le
risposte dal pannello. Per lo stesso motivo il controllo gira **prima** di costruire
qualunque cosa condivisa, log su file compreso: da qui `Log.important`, che persiste
anche a debug spento.

`LSMultipleInstancesProhibited` nell'Info.plist sarebbe stata la scorciatoia, ed è
stata scartata di proposito: la deciderebbe LaunchServices prima che il nostro codice
esista, quindi non lascerebbe scampo a chi sviluppa. Il controllo a runtime invece si
salta con `CLAUDELIVE_ALLOW_SECOND_INSTANCE=1`.

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
├── Notifications/              UsageNotifier, WaitingInputNotifier, NotificationSound
├── MenuBar/                    MenuBarController
├── PanelUI/                    FloatingPanel (AppKit) + PanelController + viste SwiftUI
└── Settings/                   finestra impostazioni
```

Le viste in `PanelUI` non toccano AppKit e ricevono i comandi tramite `PanelActions`:
è quello che permetterà di riusare `PanelRootView` nella futura modalità notch,
sostituendo solo `FloatingPanel`/`PanelController`.
