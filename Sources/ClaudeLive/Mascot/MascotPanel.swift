import AppKit

/// La finestrella che ospita il personaggio.
///
/// Parente stretta di `FloatingPanel` — stessa famiglia di problemi, stesse
/// soluzioni — ma con tre differenze che contano:
///
///   * **non diventa mai la finestra attiva.** Il pannello flottante ha dei
///     pulsanti dentro, quindi deve poter ricevere i tasti; qui non c'è niente
///     da digitare, e rinunciare del tutto a `canBecomeKey` è la garanzia più
///     forte che cliccare il pupazzetto non tolga il fuoco a VS Code. Quando
///     arriverà la barretta di input questa riga andrà rivista, ed è l'unica.
///   * **niente ombra.** L'ombra di macOS segue il rettangolo della finestra,
///     non la sagoma del personaggio: su un disegno con lo sfondo trasparente
///     comparirebbe un alone squadrato che tradisce la finestra.
///   * **non si sposta da sola.** `isMovableByWindowBackground` sposterebbe la
///     finestra senza dirci niente, e a noi il trascinamento serve raccontato —
///     direzione e velocità diventano l'inclinazione del personaggio. Se ne
///     occupa `MascotDragView`.
final class MascotPanel: NSPanel {
    /// Vero solo mentre la barra di input è aperta.
    ///
    /// È l'eccezione prevista nel commento qui sopra: per scrivere dentro una
    /// casella di testo bisogna per forza prendersi la tastiera, e in quel
    /// momento è esattamente quello che l'utente ha chiesto cliccando. Chiusa la
    /// barra torna `false`, e il pupazzetto ridiventa una cosa che si può
    /// cliccare senza conseguenze.
    var acceptsTyping = false {
        didSet {
            guard acceptsTyping != oldValue else { return }
            // Il sistema si tiene in cache lo stato di «può diventare attiva»:
            // senza questo, la finestra resta non digitabile finché non la si
            // riordina.
            if !acceptsTyping, isKeyWindow { resignKey() }
        }
    }

    /// Esc. Vedi `cancelOperation`.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // **Falso**, al contrario degli altri pannelli di questa app: con
        // `true` un pannello diventa attivo solo quando si clicca dentro una
        // vista che chiede la tastiera, e `makeKeyAndOrderFront` non basta più.
        // Il risultato era una barra che si apriva e non si poteva scrivere.
        // Qui non serve: `canBecomeKey` è già falso tranne che a barra aperta.
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false

        // `.floating` (3) e non `.statusBar` (25) come il notch: il pupazzetto sta
        // sopra le finestre normali, ma non ha nessun motivo di stare sopra la
        // barra dei menu o un menu aperto.
        level = .floating

        collectionBehavior = Self.stickyBehavior

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isMovable = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        animationBehavior = .none
        isRestorable = false
    }

    /// Su tutte le scrivanie, sopra le app a tutto schermo, e fuori dal giro di
    /// Cmd-Tab e di Mission Control.
    static let stickyBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    /// Riaggancia la finestra alla scrivania appena diventata attiva.
    ///
    /// `canJoinAllSpaces` non è retroattivo: vale per le scrivanie che esistono
    /// quando la finestra viene mostrata, e una creata dopo non la eredita — lì
    /// la mascotte sparirebbe. Rimetterla in primo piano al cambio di scrivania
    /// è ciò che la attacca anche alla nuova. Stessa cura già applicata al
    /// pannello e al notch.
    func reassertSpacePresence() {
        collectionBehavior = Self.stickyBehavior
        orderFrontRegardless()
    }

    /// Solo con la barra aperta: è tutto il punto di una mascotte che non dà
    /// fastidio.
    override var canBecomeKey: Bool { acceptsTyping }
    override var canBecomeMain: Bool { false }

    /// Esc chiude la barra invece di chiudere la finestra, che è il
    /// comportamento predefinito di un pannello senza bordi.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
