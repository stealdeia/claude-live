import CoreGraphics
import Foundation

/// Cosa c'è attorno al personaggio in questo momento.
public struct MascotChrome: Equatable, Sendable {
    /// Il fumetto sopra la testa. Zero quando non c'è.
    public var bubbleHeight: CGFloat
    /// La riga per rispondere, sotto. Zero quando non c'è.
    public var barHeight: CGFloat
    /// Quanto sono larghi fumetto e barra (sono larghi uguale).
    public var accessoryWidth: CGFloat
    /// Lo stacco fra il personaggio e quello che gli sta attorno.
    public var gap: CGFloat

    public init(
        bubbleHeight: CGFloat = 0,
        barHeight: CGFloat = 0,
        accessoryWidth: CGFloat = 0,
        gap: CGFloat = 10
    ) {
        self.bubbleHeight = bubbleHeight
        self.barHeight = barHeight
        self.accessoryWidth = accessoryWidth
        self.gap = gap
    }

    public var hasAnything: Bool { bubbleHeight > 0 || barHeight > 0 }
}

/// Una riga sopra o sotto il personaggio.
public enum MascotRow: Equatable, Sendable {
    case bubble
    case bar
}

/// Dove va la finestra, e dove stanno le cose dentro di essa.
public struct MascotChromeFrame: Equatable, Sendable {
    /// La finestra, in coordinate globali.
    public let panel: CGRect
    /// Distanza del personaggio dal bordo sinistro della finestra.
    public let characterInset: CGFloat
    /// Distanza di fumetto e barra dallo stesso bordo.
    public let accessoryInset: CGFloat
    /// Le righe sopra il personaggio, dall'alto verso il basso.
    public let above: [MascotRow]
    /// Le righe sotto il personaggio, dall'alto verso il basso.
    public let below: [MascotRow]
    /// Dove è finito davvero l'angolo in alto a sinistra del personaggio.
    ///
    /// Di solito è quello richiesto. Diverso solo quando non c'era modo di
    /// stare dentro lo schermo altrimenti.
    public let characterTopLeft: CGPoint
}

/// Dispone il personaggio e quello che gli sta attorno.
///
/// ## La regola che conta
///
/// **Il personaggio non si sposta.** Aprendo la barra è la barra a scalare di
/// lato per restare dentro lo schermo, non il pupazzetto a scansarsi per farle
/// posto: la mascotte sta dove l'hai messa, e vederla saltare a sinistra a ogni
/// clic è esattamente il difetto per cui questa funzione esiste.
///
/// La finestra è quindi l'**unione** del personaggio e di quello che ha attorno,
/// e i due possono non essere allineati: con il pupazzetto contro il bordo
/// destro, la barra gli sbuca tutta a sinistra.
///
/// Stessa idea in verticale: la barra sta sotto, ma se sotto non c'è spazio —
/// e non ce n'è quasi mai, perché la mascotte di solito vive in fondo allo
/// schermo — passa sopra invece di spingere in su il personaggio. Solo se
/// nemmeno così ci si sta, come ultima risorsa, si sposta tutto.
public enum MascotChromeLayout {
    /// Quanto barra e fumetto stanno staccati dal bordo dello schermo quando ci
    /// finiscono contro. Il personaggio no: lui può stare dove vuole, anche
    /// appiccicato al bordo, perché ce l'hai messo tu.
    public static let screenMargin: CGFloat = 8

    public static func frame(
        characterTopLeft: CGPoint,
        characterSize: CGSize,
        chrome: MascotChrome,
        in visible: CGRect
    ) -> MascotChromeFrame {
        let character = CGRect(
            x: characterTopLeft.x,
            y: characterTopLeft.y - characterSize.height,
            width: characterSize.width,
            height: characterSize.height
        )

        guard chrome.hasAnything, chrome.accessoryWidth > 0 else {
            let panel = clampedPanel(character, in: visible)
            return MascotChromeFrame(
                panel: panel,
                characterInset: 0,
                accessoryInset: 0,
                above: [],
                below: [],
                characterTopLeft: CGPoint(x: panel.minX, y: panel.maxY)
            )
        }

        // --- Di lato: centrata sul personaggio finché ci sta, poi scalata.
        let width = chrome.accessoryWidth
        var accessoryX = character.midX - width / 2
        if width + 2 * screenMargin <= visible.width {
            accessoryX = min(
                max(accessoryX, visible.minX + screenMargin),
                visible.maxX - width - screenMargin
            )
        } else {
            accessoryX = visible.minX
        }

        // --- Sopra e sotto.
        let barBelowFits = character.minY - chrome.gap - chrome.barHeight >= visible.minY
        let barOnTop = chrome.barHeight > 0 && !barBelowFits

        let bubbleRoomAbove = visible.maxY - character.maxY
            - (barOnTop ? chrome.gap + chrome.barHeight : 0)
        let bubbleAboveFits = bubbleRoomAbove >= chrome.gap + chrome.bubbleHeight
        let bubbleOnBottom = chrome.bubbleHeight > 0 && !bubbleAboveFits

        // Dal personaggio verso l'esterno: la barra gli sta più vicina, perché
        // è quella con cui si interagisce.
        var above: [MascotRow] = []
        if barOnTop { above.append(.bar) }
        if chrome.bubbleHeight > 0 && !bubbleOnBottom { above.append(.bubble) }
        above.reverse()   // l'elenco va dall'alto verso il basso

        var below: [MascotRow] = []
        if chrome.barHeight > 0 && !barOnTop { below.append(.bar) }
        if bubbleOnBottom { below.append(.bubble) }

        let topExtra = above.reduce(0) { $0 + chrome.gap + height(of: $1, chrome) }
        let bottomExtra = below.reduce(0) { $0 + chrome.gap + height(of: $1, chrome) }

        let raw = CGRect(
            x: min(character.minX, accessoryX),
            y: character.minY - bottomExtra,
            width: max(character.maxX, accessoryX + width) - min(character.minX, accessoryX),
            height: character.height + topExtra + bottomExtra
        )

        // Ultima risorsa: se nemmeno così ci si sta, si sposta tutto — e il
        // personaggio con esso.
        let panel = clampedPanel(raw, in: visible)
        let shift = CGPoint(x: panel.minX - raw.minX, y: panel.minY - raw.minY)

        return MascotChromeFrame(
            panel: panel,
            characterInset: character.minX + shift.x - panel.minX,
            accessoryInset: accessoryX + shift.x - panel.minX,
            above: above,
            below: below,
            characterTopLeft: CGPoint(
                x: character.minX + shift.x,
                y: character.maxY + shift.y
            )
        )
    }

    private static func height(of row: MascotRow, _ chrome: MascotChrome) -> CGFloat {
        switch row {
        case .bubble: return chrome.bubbleHeight
        case .bar: return chrome.barHeight
        }
    }

    /// Riporta la finestra dentro l'area visibile, per intero quando si può.
    private static func clampedPanel(_ rect: CGRect, in visible: CGRect) -> CGRect {
        var origin = rect.origin
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - rect.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }
}
