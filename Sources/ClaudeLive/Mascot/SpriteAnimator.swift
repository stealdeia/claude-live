import AppKit
import Combine
import MascotCore

/// Fa scorrere i fotogrammi. Nient'altro.
///
/// Non sa *perché* la mascotte sta facendo quello che fa — quello è compito
/// della macchina a stati — e non sa dove sta sullo schermo. Sa solo mostrare
/// un'animazione e dire quando è finita.
///
/// ## Il consumo
///
/// La regola è una sola e vale ovunque qui dentro: **se non c'è niente da
/// animare, non c'è nessun timer acceso.** Vale per un'animazione di un
/// fotogramma solo, per la mascotte nascosta, e per `hold`, che è il modo in cui
/// il riposo vero si ottiene — un disegno fermo, zero risvegli.
///
/// I timer che restano hanno una tolleranza generosa: a 5 fotogrammi al secondo
/// non cambia niente se macOS accorpa il risveglio con un altro suo, e per il
/// portatile è la differenza fra svegliare la CPU apposta e approfittare di una
/// sveglia già in programma.
@MainActor
final class SpriteAnimator: ObservableObject {
    /// Il fotogramma da mostrare adesso.
    @Published private(set) var image: NSImage?

    /// Lo stato in riproduzione.
    private(set) var state: MascotState = .idle

    /// Chiamato quando un'animazione non ciclica arriva in fondo, con lo stato
    /// verso cui il manifesto dice di proseguire (se lo dice). Nella fase 3 è
    /// l'aggancio della macchina a stati.
    var onFinished: ((MascotState, MascotState?) -> Void)?

    private var sprites: MascotSprites?
    private var animation: MascotAnimation?
    private var position = 0
    private var timer: Timer?
    /// Vero quando la mascotte non è sullo schermo: si smette proprio di
    /// disegnare, invece di disegnare per nessuno.
    private var isPaused = false

    var mascotName: String? { sprites?.manifest.name }

    func load(_ sprites: MascotSprites) {
        self.sprites = sprites
        // Ricomincia lo stato corrente con i disegni nuovi: cambiare mascotte
        // non deve lasciare in mano il fotogramma della precedente.
        play(state, restart: true)
    }

    /// Manda in scena uno stato.
    ///
    /// - Parameters:
    ///   - once: riproduce una volta sola anche un'animazione ciclica. È così
    ///     che `idle` diventa una cosina ogni tanto invece di un moto perpetuo.
    ///   - restart: riparte dal primo fotogramma anche se lo stato è già quello.
    func play(_ state: MascotState, once: Bool = false, restart: Bool = false) {
        guard let sprites else { return }
        let animation = sprites.manifest.animation(for: state)

        let sameAnimation = self.state == state && self.animation == animation
        guard !sameAnimation || restart else { return }

        self.state = state
        self.animation = once
            ? MascotAnimation(
                state: animation.state,
                frames: animation.frames,
                fps: animation.fps,
                loops: false,
                next: animation.next
            )
            : animation
        position = 0
        showCurrentFrame()
        restartTimer()
    }

    /// Ferma la mascotte su un disegno e spegne tutto.
    ///
    /// Il riposo vero: nessun timer, nessun risveglio, il fotogramma resta lì.
    func hold(_ state: MascotState) {
        guard let sprites else { return }
        self.state = state
        animation = sprites.manifest.animation(for: state)
        position = 0
        showCurrentFrame()
        stopTimer()
    }

    /// La mascotte è sparita dallo schermo: si smette di animare del tutto.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        stopTimer()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        restartTimer()
    }

    // MARK: - Il motore

    private func restartTimer() {
        stopTimer()
        guard !isPaused, let animation, !animation.isStill else { return }

        let interval = animation.frameDuration
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        // Un quinto del passo: a questi ritmi è invisibile, e permette a macOS di
        // accorpare la sveglia con altre invece di farne una apposta.
        timer.tolerance = interval * 0.2
        // `.common` e non il ciclo di default: durante un trascinamento o mentre
        // un menu è aperto il ciclo di esecuzione cambia modo, e un timer
        // normale si fermerebbe proprio mentre la mascotte è in mano.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func advance() {
        guard let animation else { return }
        guard let next = animation.position(after: position) else {
            // Finita: si resta sull'ultimo fotogramma e si spegne il timer. Chi
            // ascolta decide cosa viene dopo.
            stopTimer()
            onFinished?(animation.state, animation.next)
            return
        }
        position = next
        showCurrentFrame()
    }

    private func showCurrentFrame() {
        guard let sprites, let animation,
              animation.frames.indices.contains(position)
        else { return }
        image = sprites.frame(at: animation.frames[position])
    }
}
