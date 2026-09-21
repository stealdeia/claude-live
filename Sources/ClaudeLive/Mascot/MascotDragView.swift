import AppKit

/// Il trascinamento, gestito a mano in AppKit.
///
/// SwiftUI ha `DragGesture`, e in una finestra normale sarebbe la scelta ovvia.
/// Qui no, per due motivi: la finestra non diventa mai attiva — quindi i gesti
/// di SwiftUI arriverebbero solo dopo un primo clic speso ad attivarla — e il
/// personaggio deve sapere *come* lo stai spostando, non solo dove: direzione e
/// velocità diventano la sua inclinazione mentre penzola.
///
/// Intercetta tutti i clic, anche quelli sopra la vista SwiftUI sottostante: il
/// contenuto è un disegno, non un comando. Quando arriverà la barretta di input
/// questa regola andrà limitata al solo personaggio.
final class MascotDragView: NSView {
    /// Il trascinamento è cominciato davvero (superata la soglia).
    var onDragBegan: (() -> Void)?
    /// Nuovo angolo in alto a sinistra proposto, e velocità orizzontale in
    /// punti al secondo — positiva verso destra.
    var onDragMoved: ((CGPoint, CGFloat) -> Void)?
    /// Rilasciato: l'angolo in alto a sinistra dove la finestra è rimasta.
    var onDragEnded: ((CGPoint) -> Void)?
    /// Doppio clic sul personaggio.
    var onDoubleClick: (() -> Void)?
    /// Tasto destro: l'evento serve per far comparire il menu dove si è cliccato.
    var onContextMenu: ((NSEvent) -> Void)?
    /// Clic singolo: vero quando è caduto sul personaggio, falso quando è
    /// caduto su quello che ha attorno (la barra-invito).
    var onClick: ((Bool) -> Void)?

    /// Vero mentre si sta scrivendo nella barra: da lì in poi solo l'area del
    /// personaggio risponde al mouse, e il resto della finestra va a SwiftUI —
    /// altrimenti trascinare per selezionare del testo sposterebbe la mascotte.
    var characterOnly = false

    /// Dove sta il personaggio dentro la finestra.
    ///
    /// Lo decide il controller: con la barra aperta la finestra è più larga del
    /// pupazzetto e lui può stare ovunque dentro di essa, anche tutto a destra.
    /// Nil finché non è stato calcolato: allora vale tutta la vista.
    var characterFrame: NSRect?

    /// Sotto questa distanza è un clic, non un trascinamento.
    ///
    /// Senza soglia ogni clic finirebbe per riscrivere la posizione salvata, e
    /// un tremolio della mano basterebbe a spostare il personaggio di un pixel
    /// e a farlo «atterrare».
    ///
    /// Era 3 punti, e con 3 punti **un clic normale non esisteva**: la mano si
    /// muove sempre di qualcosa fra il premere e il rilasciare, quindi ogni
    /// tentativo di aprire la barra veniva letto come un trascinamento e la
    /// barra non si apriva mai. Segnalato il 2026-09-21, ed è il genere di
    /// difetto che dal codice sembra corretto.
    private let dragThreshold: CGFloat = 6

    /// Un clic un po' mosso resta un clic.
    ///
    /// La soglia da sola non basta: chi clicca in fretta può superarla lo
    /// stesso. Se la pressione è stata breve **e** il puntatore è tornato lì
    /// intorno, l'intenzione era cliccare, e il trascinamento appena cominciato
    /// si chiude e si conta come clic.
    private let clickMaxDuration: TimeInterval = 0.35
    private let clickSlop: CGFloat = 14

    private var mouseDownAt: CGPoint = .zero
    private var mouseDownTime: TimeInterval = 0
    private var topLeftAtMouseDown: CGPoint = .zero
    private var isDragging = false
    private var lastPoint: CGPoint = .zero
    private var lastMoveTime: TimeInterval = 0

    /// Il primo clic deve trascinare, non «svegliare» la finestra: senza questo
    /// il primo trascinamento con un'altra app in primo piano andrebbe perso.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Lo spostamento lo fa `MascotController`, non macOS.
    override var mouseDownCanMoveWindow: Bool { false }

    /// La manina aperta quando ci si passa sopra.
    ///
    /// `.activeAlways` e non `.activeInActiveApp`: la finestra della mascotte non
    /// diventa mai attiva, quindi con le opzioni normali il cursore non
    /// cambierebbe mai.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    private var characterRect: NSRect { characterFrame ?? bounds }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arriva nelle coordinate della supervista; per la vista
        // contenuto di una finestra la supervista è nil, cioè la finestra.
        let local = convert(point, from: superview)
        let area = characterOnly ? characterRect : bounds
        return area.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        pendingClick?.cancel()
        pendingClick = nil
        mouseDownAt = NSEvent.mouseLocation
        mouseDownTime = event.timestamp
        topLeftAtMouseDown = CGPoint(x: window.frame.minX, y: window.frame.maxY)
        lastPoint = mouseDownAt
        lastMoveTime = event.timestamp
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownAt.x
        let dy = now.y - mouseDownAt.y

        if !isDragging {
            guard hypot(dx, dy) > dragThreshold else { return }
            isDragging = true
            // La manina chiusa mentre lo si tiene: è il modo in cui macOS dice
            // «questo si sposta», e costa una riga.
            NSCursor.closedHand.push()
            onDragBegan?()
        }

        let elapsed = event.timestamp - lastMoveTime
        // Un intervallo nullo darebbe una velocità infinita; capita davvero,
        // perché due eventi possono portare lo stesso timestamp.
        let velocity = elapsed > 0 ? (now.x - lastPoint.x) / CGFloat(elapsed) : 0
        lastPoint = now
        lastMoveTime = event.timestamp

        onDragMoved?(
            CGPoint(x: topLeftAtMouseDown.x + dx, y: topLeftAtMouseDown.y + dy),
            velocity
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    /// Il clic singolo in attesa di sapere se era il primo di un doppio.
    private var pendingClick: DispatchWorkItem?

    override func mouseUp(with event: NSEvent) {
        let here = NSEvent.mouseLocation
        let displacement = hypot(here.x - mouseDownAt.x, here.y - mouseDownAt.y)
        let quick = event.timestamp - mouseDownTime < clickMaxDuration

        // Un trascinamento cominciato si chiude sempre, anche quando poi si
        // rivela un clic: la macchina a stati ha già visto il personaggio
        // sollevato, e lasciarlo lì in aria sarebbe peggio di qualunque
        // ambiguità del gesto.
        if isDragging, let window {
            isDragging = false
            NSCursor.pop()
            onDragEnded?(CGPoint(x: window.frame.minX, y: window.frame.maxY))

            // Breve e tornato al punto di partenza: era un clic.
            guard quick, displacement <= clickSlop else { return }
        }

        // Il doppio clic si riconosce solo se non si è trascinato: prendere in
        // mano il pupazzetto due volte di fila non è un doppio clic.
        if event.clickCount == 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onDoubleClick?()
            return
        }

        // Un clic singolo apre la barra, un doppio apre il progetto: per sapere
        // quale dei due è, bisogna aspettare quanto dice il sistema. Sono due o
        // tre decimi, e sono il prezzo per avere due gesti diversi sullo stesso
        // pupazzetto.
        if event.clickCount == 1 {
            let onCharacter = characterRect.contains(convert(event.locationInWindow, from: nil))
            let work = DispatchWorkItem { [weak self] in
                self?.pendingClick = nil
                self?.onClick?(onCharacter)
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NSEvent.doubleClickInterval, execute: work
            )
        }
    }

}
