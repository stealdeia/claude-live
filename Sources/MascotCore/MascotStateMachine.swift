import Foundation

/// Decide cosa deve fare il personaggio, e quando.
///
/// Sta qui dentro tutto il comportamento della mascotte, e *solo* quello:
/// niente finestre, niente timer, niente immagini. Riceve dei fatti — è arrivata
/// una notizia, è cominciato un trascinamento, è passato del tempo — e risponde
/// con un'azione da far eseguire a qualcun altro. È quello che la rende
/// collaudabile senza aprire una finestra: una macchina a stati che si guarda
/// solo dall'esterno non si può provare, e questa è la parte con le regole più
/// facili da sbagliare.
///
/// ## Il riposo
///
/// `idle` e `sleeping` non sono animazioni che girano: sono un **disegno fermo**
/// su cui il personaggio si posa, più una cosina ogni tanto — un battito di
/// ciglia, uno sbadiglio, una zeta che sale. Fra una cosina e l'altra non c'è
/// nessun timer acceso e nessun disegno da rifare, ed è così che una mascotte
/// che sta lì tutto il giorno costa davvero zero. La differenza con un `idle`
/// che cicla è piccola a vedersi e grande a sentirsi sulla ventola.
public struct MascotStateMachine {
    /// Le durate, tutte in un posto solo e tutte modificabili.
    public struct Timing: Equatable, Sendable {
        /// Dopo quanto silenzio si addormenta.
        public var sleepAfter: TimeInterval
        /// Ogni quanto fa una cosina mentre è ferma. Un intervallo e non un
        /// numero: a cadenza fissa si vedrebbe il meccanismo.
        public var fidgetEvery: ClosedRange<TimeInterval>
        /// Ogni quanto si muove nel sonno. Più rado: dorme.
        public var snoreEvery: ClosedRange<TimeInterval>

        public init(
            sleepAfter: TimeInterval = 5 * 60,
            fidgetEvery: ClosedRange<TimeInterval> = 12...28,
            snoreEvery: ClosedRange<TimeInterval> = 25...50
        ) {
            self.sleepAfter = sleepAfter
            self.fidgetEvery = fidgetEvery
            self.snoreEvery = snoreEvery
        }
    }

    /// I fatti che la macchina sa ricevere.
    public enum Input: Equatable, Sendable {
        case event(MascotEvent)
        case dragBegan
        case dragEnded
        /// Un'animazione non ciclica è arrivata in fondo.
        case animationFinished(MascotState)
        /// La mascotte è comparsa sullo schermo.
        case appeared
        /// La mascotte è sparita: da qui in poi non si decide più niente,
        /// perché non c'è nessuno a guardare.
        case disappeared
    }

    /// Cosa farne. Chi la esegue è `SpriteAnimator`, che di stati non sa niente.
    public enum Action: Equatable, Sendable {
        /// Manda in scena un'animazione; `once` anche se è ciclica.
        case play(MascotState, once: Bool)
        /// Posala su un disegno fermo e spegni tutto.
        case hold(MascotState)
    }

    public private(set) var state: MascotState = .idle
    public var timing: Timing

    /// Sostituibile: nelle prove serve una cadenza prevedibile, altrimenti la
    /// prova dipenderebbe dal caso.
    public var randomInterval: (ClosedRange<TimeInterval>) -> TimeInterval = { Double.random(in: $0) }

    private var isWorking = false
    private var isDragging = false
    /// L'animazione una-tantum in corso: `notify` o `dropped`. Finché c'è, vince
    /// su tutto il resto tranne il trascinamento.
    private var transient: MascotState?
    /// L'ultima volta che è successo qualcosa. Da qui si conta il sonno.
    private var lastActivity: Date
    /// Quando tocca fare la prossima cosina.
    private var nextBurst: Date?
    private var isVisible = false

    public init(now: Date, timing: Timing = Timing()) {
        self.timing = timing
        self.lastActivity = now
    }

    /// Gli stati in cui il personaggio sta fermo e ogni tanto si muove.
    private var isResting: Bool { state == .idle || state == .sleeping }

    private var burstRange: ClosedRange<TimeInterval> {
        state == .sleeping ? timing.snoreEvery : timing.fidgetEvery
    }

    /// Quando vale la pena richiamare `tick`.
    ///
    /// Un solo istante, non un timer al secondo: chi la usa accende una sveglia
    /// sola e lunga, la spegne quando qui non c'è niente da aspettare, e quindi
    /// una mascotte ferma non fa succedere niente a nessuno.
    public var nextWakeUp: Date? {
        guard isVisible else { return nil }
        var candidates: [Date] = []
        if let nextBurst { candidates.append(nextBurst) }
        // Il sonno si conta solo da sveglia e senza niente per le mani.
        if state == .idle {
            candidates.append(lastActivity.addingTimeInterval(timing.sleepAfter))
        }
        return candidates.min()
    }

    // MARK: - Ingressi

    public mutating func handle(_ input: Input, now: Date) -> Action? {
        var restart = false

        switch input {
        case .event(let event):
            lastActivity = now
            switch event {
            case .working(let isOn):
                isWorking = isOn
            case .notice:
                // Una notizia mentre ne sta già annunciando un'altra fa
                // ricominciare il salto: due cose successe sono due cose da far
                // notare, non una.
                restart = state == .notify
                transient = .notify
            case .poked:
                break
            }

        case .dragBegan:
            lastActivity = now
            isDragging = true
            // Prenderlo in mano interrompe qualunque cosa stesse annunciando:
            // adesso sta succedendo questo.
            transient = nil

        case .dragEnded:
            lastActivity = now
            isDragging = false
            transient = .dropped
            restart = state == .dropped

        case .animationFinished(let finished):
            if finished == transient {
                transient = nil
            } else if finished == state, isResting {
                // Era una cosina: si torna fermi e si dà appuntamento alla
                // prossima.
                nextBurst = now.addingTimeInterval(randomInterval(burstRange))
                return .hold(state)
            }

        case .appeared:
            isVisible = true
            lastActivity = now
            // Si riparte sempre da fermi: quello che stava facendo mentre era
            // nascosta non l'ha visto nessuno.
            state = .idle
            transient = nil
            nextBurst = now.addingTimeInterval(randomInterval(timing.fidgetEvery))
            return .hold(.idle)

        case .disappeared:
            isVisible = false
            nextBurst = nil
            return nil
        }

        // Nascosta i fatti si continuano a segnare — il lavoro in corso resta
        // in corso anche se nessuno lo vede — ma non si mette in scena niente
        // per una platea che non c'è.
        guard isVisible else { return nil }

        return settle(now: now, restart: restart)
    }

    /// Il passare del tempo: il sonno e le cosine.
    public mutating func tick(now: Date) -> Action? {
        guard isVisible else { return nil }

        // Prima se lo stato è cambiato, poi la cosina: se sono scadute tutte e
        // due — succede ogni volta che ci si addormenta, perché l'ultimo
        // appuntamento cade sempre prima — addormentarsi è la notizia, lo
        // sbadiglio no.
        if let action = settle(now: now, restart: false) { return action }

        if let due = nextBurst, now >= due, isResting, transient == nil, !isDragging {
            nextBurst = nil
            return .play(state, once: true)
        }
        return nil
    }

    // MARK: - La regola

    /// Quello che il personaggio dovrebbe stare facendo adesso.
    ///
    /// L'ordine è la regola: chi sta più in alto vince. Il trascinamento batte
    /// tutto perché è l'unica cosa che sta facendo l'utente in quel momento, e
    /// una notizia batte il lavoro in corso perché è un fatto appena successo,
    /// mentre il lavoro è uno sfondo che dura.
    private func desiredState(now: Date) -> MascotState {
        if isDragging { return .dragging }
        if let transient { return transient }
        if isWorking { return .working }
        if now.timeIntervalSince(lastActivity) >= timing.sleepAfter { return .sleeping }
        return .idle
    }

    private mutating func settle(now: Date, restart: Bool) -> Action? {
        let desired = desiredState(now: now)
        guard desired != state || restart else { return nil }

        state = desired
        switch desired {
        case .idle, .sleeping:
            nextBurst = now.addingTimeInterval(randomInterval(burstRange))
            return .hold(desired)
        case .working, .dragging:
            nextBurst = nil
            return .play(desired, once: false)
        case .notify, .dropped:
            nextBurst = nil
            return .play(desired, once: true)
        }
    }
}
