import AppKit
import Combine
import SwiftUI
import ClaudeLiveKit
import MascotCore

/// Tiene la mascotte sullo schermo: quando c'è, dove sta, e come ci resta.
///
/// Stessa divisione dei compiti del pannello flottante: qui dentro tutto quello
/// che è AppKit — finestra, schermi, scrivanie, trascinamento — e nella vista
/// SwiftUI solo il disegno. È ciò che permetterà, nella fase 2, di sostituire il
/// rettangolo con uno sprite senza toccare una riga di questo file.
@MainActor
final class MascotController: NSObject {
    private let settings: Settings
    private let panel: MascotPanel
    private let dragView = MascotDragView()
    private let appearance = MascotAppearance()
    private let animator = SpriteAnimator()
    /// Condiviso con le Impostazioni, che mostrano le stesse mascotte con le
    /// stesse anteprime: caricarle due volte vorrebbe dire poterle avere diverse.
    private let store: MascotStore
    private let hosting: NSHostingView<MascotView>

    /// Le regole: cosa fa il personaggio, e quando. Vedi `MascotStateMachine`.
    private var machine = MascotStateMachine(now: Date())
    /// L'unica sveglia della mascotte: una sola, e solo se c'è qualcosa da
    /// aspettare. Vedi `rescheduleTick`.
    private var tickTimer: Timer?

    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: Any?
    private var spaceObserver: Any?

    /// Quanta velocità di trascinamento fa un grado di inclinazione, e fin dove.
    /// Numeri a occhio: servono a far penzolare il personaggio, non a simulare
    /// niente.
    private let tiltPerPointPerSecond: Double = 1.0 / 90
    private let maxTilt: Double = 16

    /// Cosa fare quando ci si clicca sopra due volte, e cosa quando si chiedono
    /// le Impostazioni dal menu contestuale.
    ///
    /// Chiusure e non riferimenti ai progetti o allo stato di Claude Code: la
    /// mascotte non deve sapere cos'è un progetto. Decide chi la monta.
    private let onOpenProject: () -> Void
    private let onOpenSettings: () -> Void

    /// Dove va a finire quello che si scrive nella barra.
    private let router: MascotPromptRouter
    /// Cosa è rimasto in sospeso: il pallino e l'elenco nel fumetto.
    private let inbox: MascotInbox

    /// La posizione del **personaggio**, angolo in alto a sinistra, in
    /// coordinate globali.
    ///
    /// Del personaggio e non della finestra, perché la finestra cambia
    /// larghezza quando la barra si apre: se la posizione fosse quella della
    /// finestra, aprire la barra sposterebbe il pupazzetto di ottantasei punti.
    /// Quella che si salva, e quella che si riporta dentro lo schermo, è sempre
    /// questa.
    private var characterTopLeft: CGPoint = .zero

    /// L'app che aveva la tastiera prima che la barra la prendesse, per poterle
    /// restituire tutto chiudendo.
    private var appBeforeTyping: NSRunningApplication?

    /// Cancella l'avviso sotto la barra dopo qualche secondo.
    private var noticeTask: Task<Void, Never>?
    /// Toglie il fumetto quando è stato lì abbastanza.
    private var bubbleTask: Task<Void, Never>?

    init(
        settings: Settings,
        store: MascotStore,
        router: MascotPromptRouter,
        inbox: MascotInbox,
        events: MascotEventSource? = nil,
        onOpenProject: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.settings = settings
        self.store = store
        self.router = router
        self.inbox = inbox
        self.onOpenProject = onOpenProject
        self.onOpenSettings = onOpenSettings

        let size = MascotLayout.characterSize
        panel = MascotPanel(contentRect: NSRect(origin: .zero, size: size))
        // Chiusure vuote per ora: si rimettono quelle vere appena `self` esiste.
        hosting = NSHostingView(
            rootView: MascotView(
                animator: animator, appearance: appearance, router: router,
                onSubmit: {}, onCloseBar: {}, onDismissBubble: {},
                onOpenItem: { _ in }, onDecide: { _, _ in }, onAnswer: { _, _, _ in }
            )
        )

        dragView.frame = NSRect(origin: .zero, size: size)
        hosting.frame = dragView.bounds
        hosting.autoresizingMask = [.width, .height]
        dragView.addSubview(hosting)
        panel.contentView = dragView

        // Le voci del menu contestuale sono azioni AppKit, e quelle vogliono un
        // `NSObject` a cui essere consegnate.
        super.init()

        hosting.rootView = MascotView(
            animator: animator,
            appearance: appearance,
            router: router,
            onSubmit: { [weak self] in self?.submitDraft() },
            onCloseBar: { [weak self] in self?.setBarMode(.hidden) },
            onDismissBubble: { [weak self] in self?.dismissBubble() },
            onOpenItem: { [weak self] item in
                self?.inbox.open(item)
                self?.closeEverything()
            },
            onDecide: { [weak self] item, allow in
                self?.inbox.decide(item, allow: allow)
                self?.closeEverything()
            },
            onAnswer: { [weak self] item, question, label in
                self?.inbox.answer(item, question: question, label: label)
                self?.closeEverything()
            }
        )
        panel.onCancel = { [weak self] in self?.setBarMode(.hidden) }

        wireDragging()
        loadSprites()

        // Un'animazione finita è un fatto come gli altri: decide la macchina
        // cosa viene dopo, non l'animatore.
        animator.onFinished = { [weak self] finished, _ in
            guard let self else { return }
            self.perform(self.machine.handle(.animationFinished(finished), now: Date()))
        }

        inbox.$items
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                Task { @MainActor in self?.updateUnread(count) }
            }
            .store(in: &cancellables)

        // Le notizie. Da qui in poi la mascotte reagisce a Claude Code senza
        // sapere che esiste: vedi `ClaudeMascotEventSource`.
        (events ?? MascotEventBus.shared).events
            .sink { [weak self] event in
                guard let self else { return }
                if case .notice(let notice) = event { self.announce(notice) }
                self.perform(self.machine.handle(.event(event), now: Date()))
            }
            .store(in: &cancellables)

        settings.$mascotID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.loadSprites() }
            }
            .store(in: &cancellables)

        // Scegliere una cartella personalizzata cambia l'elenco, non solo la
        // scelta: i disegni vanno ricaricati anche se l'identificativo è lo
        // stesso di prima.
        store.$entries
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.loadSprites() }
            }
            .store(in: &cancellables)

        // L'interruttore nelle Impostazioni e la voce nel menu scrivono la stessa
        // preferenza: seguendo quella invece di offrire due comandi, le due cose
        // non possono dire il contrario l'una dell'altra.
        settings.$mascotEnabled
            // `dropFirst` perché l'accensione all'avvio la decide `showIfEnabled`,
            // chiamato quando tutto il resto è pronto: qui interessano solo i
            // cambi successivi, cioè l'utente che tocca l'interruttore.
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in enabled ? self?.show() : self?.hide() }
            }
            .store(in: &cancellables)

        // Monitor scollegato, risoluzione cambiata, coperchio chiuso: la
        // posizione salvata può essere finita fuori da qualunque schermo.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyStoredPosition() }
        }

        // Una scrivania creata dopo il lancio non eredita `canJoinAllSpaces`.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.panel.reassertSpacePresence()
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Da chiamare all'avvio: mostra la mascotte solo se era accesa.
    func showIfEnabled() {
        guard settings.mascotEnabled else { return }
        show()
    }

    /// Carica i disegni della mascotte scelta.
    private func loadSprites() {
        guard let entry = store.entry(withID: settings.mascotID) else {
            Log.error("Nessun disegno da mostrare: la mascotte resta nascosta", category: .mascot)
            return
        }
        animator.load(entry.sprites)
        // L'identificativo salvato può non esistere più — mascotte tolta da un
        // aggiornamento, cartella spostata. Si riallinea a quella che si è
        // riusciti a caricare, così le Impostazioni mostrano la verità.
        if settings.mascotID != entry.id { settings.mascotID = entry.id }
        Log.info("Mascotte caricata: «\(entry.name)» (\(entry.sprites.count) fotogrammi)", category: .mascot)
    }

    /// Il pulsante «Prova» nelle Impostazioni.
    ///
    /// Manda un evento vero sul canale invece di comandare l'animatore: così la
    /// prova percorre esattamente la stessa strada che percorre un turno finito
    /// davvero, macchina a stati compresa. Una prova che scavalca metà del
    /// meccanismo direbbe poco.
    func previewNotify() {
        MascotEventBus.shared.post(.notice(MascotNotice(
            kind: .finished,
            project: "prova",
            detail: "Così si comporta quando ho finito qualcosa."
        )))
    }

    func show() {
        guard animator.image != nil else {
            Log.error("Mascotte accesa ma senza disegni: non mostro una finestra vuota", category: .mascot)
            return
        }
        applyStoredPosition()
        animator.resume()
        // Come per il pannello: in primo piano senza attivare l'app, così quello
        // che stavi scrivendo resta dov'è.
        panel.orderFrontRegardless()
        perform(machine.handle(.appeared, now: Date()))
        Log.debug("Mascotte mostrata", category: .mascot)
    }

    func hide() {
        setBarMode(.hidden)
        panel.orderOut(nil)
        perform(machine.handle(.disappeared, now: Date()))
        // Fuori dallo schermo non si anima per nessuno.
        animator.pause()
        Log.debug("Mascotte nascosta", category: .mascot)
    }

    func toggle() {
        settings.mascotEnabled.toggle()
    }

    // MARK: - Trascinamento

    private func wireDragging() {
        dragView.onDragBegan = { [weak self] in
            guard let self else { return }
            self.perform(self.machine.handle(.dragBegan, now: Date()))
        }

        dragView.onDragMoved = { [weak self] topLeft, velocity in
            guard let self else { return }
            let tilt = (Double(velocity) * self.tiltPerPointPerSecond)
                .clamped(to: -self.maxTilt...self.maxTilt)
            self.appearance.tilt = tilt
            self.applyChrome(moveTo: self.character(fromPanel: topLeft), on: self.screenUnderCursor())
        }

        dragView.onClick = { [weak self] onCharacter in
            guard let self else { return }
            MascotEventBus.shared.post(.poked)

            guard onCharacter else {
                // Clic sulla barra-invito: quello che si vuole è scrivere.
                self.setBarMode(.typing)
                return
            }

            // Sul personaggio: se c'è già qualcosa aperto si chiude tutto,
            // altrimenti si apre tutto quello che ha da dire — l'elenco delle
            // cose non viste sopra, la riga per scrivere sotto.
            if self.appearance.bubble != nil || self.appearance.isBarVisible {
                self.closeEverything()
            } else {
                self.openInbox()
            }
        }

        dragView.onDoubleClick = { [weak self] in
            guard let self else { return }
            // Un doppio clic è comunque un segno di vita: se dormiva, si sveglia.
            MascotEventBus.shared.post(.poked)
            self.setBarMode(.hidden)
            self.onOpenProject()
        }

        dragView.onContextMenu = { [weak self] event in
            self?.showContextMenu(for: event)
        }

        dragView.onDragEnded = { [weak self] topLeft in
            guard let self else { return }
            self.appearance.tilt = 0
            self.perform(self.machine.handle(.dragEnded, now: Date()))
            self.characterTopLeft = self.character(fromPanel: topLeft)
            self.remember()
        }
    }

    /// Lo schermo sotto il puntatore, così trascinando da un monitor all'altro il
    /// personaggio passa davvero di là invece di restare incollato al bordo del
    /// primo.
    private func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    /// Lo schermo su cui la mascotte sta adesso.
    private func currentScreen() -> NSScreen? {
        panel.screen ?? screenUnderCursor() ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// L'angolo del personaggio, dato quello della finestra.
    ///
    /// Non è più una semplice metà della differenza: con la barra aperta il
    /// personaggio può stare ovunque dentro la finestra, anche tutto a destra.
    private func character(fromPanel topLeft: CGPoint) -> CGPoint {
        CGPoint(
            x: topLeft.x + (appearance.chrome?.characterInset ?? 0),
            y: topLeft.y - topInset
        )
    }

    /// Quanto la finestra sporge sopra la testa del personaggio (il fumetto).
    private var topInset: CGFloat {
        guard let chrome = appearance.chrome else { return 0 }
        return chrome.panel.maxY - chrome.characterTopLeft.y
    }

    /// Ricalcola dove va tutto, e sposta la finestra.
    ///
    /// Il punto fermo è il **personaggio**: fumetto e barra gli si dispongono
    /// attorno, sfalsandosi se serve per restare dentro lo schermo. Vedi
    /// `MascotChromeLayout`, dove sta la regola vera.
    private func applyChrome(moveTo desired: CGPoint? = nil, on screen: NSScreen? = nil) {
        guard let screen = screen ?? currentScreen() else { return }

        let frame = MascotChromeLayout.frame(
            characterTopLeft: desired ?? characterTopLeft,
            characterSize: MascotLayout.characterSize,
            chrome: MascotLayout.chrome(
                bubble: appearance.bubble,
                bar: appearance.isBarVisible
            ),
            in: screen.visibleFrame
        )

        characterTopLeft = frame.characterTopLeft
        appearance.chrome = frame
        panel.setFrame(frame.panel, display: true)

        // Dove cliccare per prendere in mano il pupazzetto: la finestra è più
        // grande di lui, e il resto appartiene a fumetto e barra.
        let size = MascotLayout.characterSize
        dragView.characterFrame = NSRect(
            x: frame.characterInset,
            y: frame.panel.height - (frame.panel.maxY - frame.characterTopLeft.y) - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Il fumetto

    /// Fa comparire il fumetto con la notizia appena arrivata, e sotto la riga
    /// per rispondere.
    ///
    /// La riga compare **come invito**, non come campo attivo: il fumetto arriva
    /// da solo, quando Claude finisce o chiede qualcosa, e in quel momento
    /// prendersi la tastiera vorrebbe dire rubare le lettere a quello che stavi
    /// scrivendo altrove. Un clic e diventa un campo vero.
    private func announce(_ notice: MascotNotice) {
        guard panel.isVisible else { return }
        appearance.bubble = .notice(notice)
        if appearance.barMode == .hidden { appearance.barMode = .invite }
        applyChrome()
        scheduleBubbleDismissal()
    }

    /// Il fumetto con l'elenco di quello che non hai ancora visto, più la riga
    /// per scrivere: è quello che succede cliccando il personaggio.
    private func openInbox() {
        if !inbox.items.isEmpty {
            appearance.bubble = .inbox(inbox.items)
            // Aperto apposta, quindi resta: a sparire da solo è l'avviso che
            // arriva da solo, non quello che sei andato a cercare.
            bubbleTask?.cancel()
            bubbleTask = nil
        }
        setBarMode(.typing)
    }

    /// Chiude fumetto e barra insieme.
    private func closeEverything() {
        bubbleTask?.cancel()
        bubbleTask = nil
        appearance.bubble = nil
        if appearance.barMode == .hidden {
            applyChrome()
        } else {
            setBarMode(.hidden)
        }
    }

    private func dismissBubble() {
        bubbleTask?.cancel()
        bubbleTask = nil
        guard appearance.bubble != nil else { return }
        appearance.bubble = nil
        if appearance.barMode == .invite {
            setBarMode(.hidden)
        } else {
            applyChrome()
        }
    }

    /// Il fumetto arrivato da solo se ne va da solo.
    ///
    /// Ma quello che resta non si perde: il pallino sulla testa continua a dire
    /// che c'è qualcosa da guardare, ed è lì che sta la differenza fra una
    /// notifica che scompare e una notizia che aspetta.
    private func scheduleBubbleDismissal() {
        bubbleTask?.cancel()
        bubbleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard !Task.isCancelled else { return }
            // Chi sta scrivendo lo sta facendo per rispondere a questo: il
            // fumetto resta finché non ha finito.
            guard self.appearance.barMode != .typing else { return }
            self.dismissBubble()
        }
    }

    /// Quante cose non ancora viste, e — se l'elenco è aperto — quali.
    private func updateUnread(_ count: Int) {
        appearance.unread = count

        guard case .inbox = appearance.bubble else { return }
        if inbox.items.isEmpty {
            closeEverything()
        } else {
            appearance.bubble = .inbox(inbox.items)
            applyChrome()
        }
    }

    // MARK: - La barra

    /// Apre, chiude, o mette la barra in attesa di un clic.
    ///
    /// Passare a `.typing` è l'unico momento in cui la mascotte si prende la
    /// tastiera. Uscendone la restituisce a chi ce l'aveva: senza, si resterebbe
    /// con il fuoco su un'app che non ha finestre, e per tornare a scrivere in
    /// VS Code servirebbe un clic in più — proprio il fastidio che tutto il
    /// resto di questo file esiste per evitare.
    private func setBarMode(_ mode: MascotBarMode) {
        guard appearance.barMode != mode else { return }
        guard mode == .hidden || panel.isVisible else { return }

        let wasTyping = appearance.barMode == .typing
        appearance.barMode = mode
        appearance.notice = nil
        if mode == .hidden {
            bubbleTask?.cancel()
            appearance.bubble = nil
        }
        dragView.characterOnly = mode == .typing
        panel.acceptsTyping = mode == .typing

        applyChrome()

        switch mode {
        case .typing:
            appBeforeTyping = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            // Il campo compare adesso, e la finestra diventa attiva un istante
            // dopo: chiedere il cursore solo alla comparsa arriva troppo presto
            // e non succede niente. Questo è il secondo tentativo, quando la
            // tastiera è davvero nostra.
            DispatchQueue.main.async { [weak self] in self?.appearance.focusTick += 1 }
            Log.info("Barra in scrittura (\(router.target))", category: .mascot)
        case .invite, .hidden:
            panel.orderFrontRegardless()
            if wasTyping {
                appBeforeTyping?.activate()
                appBeforeTyping = nil
            }
        }
    }

    /// Manda quello che c'è scritto, e racconta com'è andata.
    private func submitDraft() {
        let outcome = router.send(appearance.draft)
        switch outcome {
        case .sent(let message), .queued(let message):
            appearance.draft = ""
            show(notice: message)
            // Si chiude da sé un attimo dopo: il messaggio è partito, e una
            // barra che resta aperta invita a scriverne un altro che spesso non
            // avrebbe più dove andare.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.setBarMode(.hidden)
            }
        case .refused(let message):
            show(notice: message)
        }
    }

    private func show(notice: String) {
        appearance.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self.appearance.notice = nil
        }
    }

    // MARK: - Menu contestuale

    /// Il menu del tasto destro.
    ///
    /// Costruito ogni volta e non tenuto da parte: le voci dipendono da cosa c'è
    /// adesso — quali mascotte sono installate, quale è in uso — e un menu
    /// costruito una volta sola direbbe la verità solo al primo clic. Stessa
    /// scelta, per la stessa ragione, del menu nella barra dei menu.
    private func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()

        let change = NSMenuItem(title: "Cambia mascotte", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for entry in store.entries {
            let item = NSMenuItem(
                title: entry.name,
                action: #selector(selectMascot(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            item.state = entry.id == settings.mascotID ? .on : .off
            // L'anteprima nel menu: riconoscere un personaggio dal nome è più
            // difficile che riconoscerlo in faccia.
            if let preview = entry.sprites.firstFrame(of: .idle) {
                let thumbnail = NSImage(size: NSSize(width: 18, height: 18))
                thumbnail.lockFocus()
                preview.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                thumbnail.unlockFocus()
                item.image = thumbnail
            }
            submenu.addItem(item)
        }
        change.submenu = submenu

        menu.addItem(withTitle: "Nascondi mascotte", action: #selector(hideFromMenu), keyEquivalent: "")
        menu.items.last?.target = self
        menu.addItem(.separator())
        menu.addItem(change)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Impostazioni…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        menu.items.last?.target = self

        NSMenu.popUpContextMenu(menu, with: event, for: dragView)
    }

    @objc private func selectMascot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.mascotID = id
    }

    @objc private func hideFromMenu() {
        settings.mascotEnabled = false
    }

    @objc private func openSettingsFromMenu() {
        onOpenSettings()
    }

    // MARK: - Esecuzione

    /// Esegue quello che la macchina ha deciso, e rimette la sveglia.
    private func perform(_ action: MascotStateMachine.Action?) {
        switch action {
        case .play(let state, let once):
            // Registrato perché è l'unico modo di capire, a cose fatte, perché
            // il personaggio ha fatto quello che ha fatto: le animazioni durano
            // un secondo e nessuno è mai lì a guardare nel momento giusto.
            Log.info("Mascotte: \(state.label)\(once ? " (una volta)" : "")", category: .mascot)
            animator.play(state, once: once, restart: true)
        case .hold(let state):
            Log.info("Mascotte: \(state.label) (disegno fermo, nessun timer)", category: .mascot)
            animator.hold(state)
        case nil:
            break
        }
        rescheduleTick()
    }

    /// Una sveglia sola, all'ora che serve.
    ///
    /// Non un timer che batte ogni secondo per chiedere «è ora?»: la macchina
    /// sa già dire quando avrà qualcosa da fare, e quando non ha niente da
    /// aspettare — mentre lavora, mentre è in mano, mentre è nascosta — non c'è
    /// proprio nessun timer acceso. È l'altra metà del consumo a riposo, quella
    /// che l'animatore da solo non potrebbe garantire.
    private func rescheduleTick() {
        tickTimer?.invalidate()
        tickTimer = nil

        guard let due = machine.nextWakeUp else { return }
        let delay = max(0.1, due.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.perform(self.machine.tick(now: Date()))
            }
        }
        // Mezzo secondo di tolleranza su attese di decine di secondi: invisibile,
        // e permette a macOS di accorpare la sveglia invece di farne una apposta.
        timer.tolerance = min(0.5, delay * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - Posizione

    /// Salva dove il personaggio è stato lasciato, in coordinate relative allo
    /// schermo su cui si trova. Vedi `MascotPlacement.relative`.
    private func remember() {
        guard let screen = currentScreen() else { return }
        let id = ScreenIdentity.identifier(for: screen)
        let relative = MascotPlacement.relative(
            topLeft: characterTopLeft, screenFrame: screen.frame
        )
        settings.setMascotPosition(relative, forScreen: id)
        Log.debug(
            "Mascotte lasciata a \(Int(relative.x)),\(Int(relative.y)) su «\(screen.localizedName)»",
            category: .mascot
        )
    }

    /// Rimette la mascotte dove era stata lasciata.
    ///
    /// Se lo schermo di allora non c'è più — scollegato, o mai più visto —
    /// riparte dall'angolo in basso a destra dello schermo principale: meglio un
    /// posto diverso che un personaggio invisibile fuori dal visibile.
    private func applyStoredPosition() {
        let size = MascotLayout.characterSize

        let placement: (point: CGPoint, screen: NSScreen)? = {
            guard let id = settings.mascotScreenID,
                  let screen = NSScreen.screens.first(where: {
                      ScreenIdentity.identifier(for: $0) == id
                  }),
                  let relative = settings.mascotPosition(forScreen: id)
            else { return nil }
            let absolute = MascotPlacement.absolute(
                relativeTopLeft: relative, screenFrame: screen.frame
            )
            return (absolute, screen)
        }()

        if let placement {
            applyChrome(moveTo: placement.point, on: placement.screen)
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let start = MascotPlacement.defaultTopLeft(size: size, in: screen.visibleFrame)
        Log.info(
            "Nessuna posizione valida per la mascotte: la metto in basso a destra su «\(screen.localizedName)»",
            category: .mascot
        )
        applyChrome(moveTo: start, on: screen)
    }
}
