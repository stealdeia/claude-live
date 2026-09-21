import CoreGraphics
import Foundation

/// Un punto salvabile su file.
///
/// `CGPoint` è già codificabile, ma si serializza come una coppia senza nomi:
/// `settings.json` è un file che si apre e si legge a occhio quando qualcosa non
/// torna, quindi i due numeri hanno un nome.
public struct MascotPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// Dove sta la mascotte sullo schermo, e come ci resta.
///
/// Logica pura, senza AppKit, per due motivi: è l'unica parte del
/// posizionamento che si può sbagliare in silenzio — una mascotte finita fuori
/// dallo schermo non la vedi, quindi non la puoi nemmeno riportare dentro — ed
/// è l'unica che si può provare senza aprire una finestra.
///
/// ## Coordinate
///
/// Tutto è nello spazio di AppKit: origine in basso a sinistra dello schermo
/// principale, **y verso l'alto**. Il punto di riferimento della mascotte è il
/// suo angolo in **alto a sinistra**, non l'origine della finestra, così il
/// valore salvato non cambia significato se un giorno la mascotte diventa più
/// alta — è la stessa scelta già fatta per il pannello flottante, e per lo
/// stesso motivo: lì la barretta di input sotto al personaggio, prevista più
/// avanti, sposterebbe tutto di qualche decina di punti.
public enum MascotPlacement {
    /// Distanza dai bordi quando la mascotte non ha ancora una posizione sua.
    public static let margin: CGFloat = 24

    /// Riporta l'angolo in alto a sinistra dentro l'area visibile, tenendo
    /// **tutta** la mascotte dentro.
    ///
    /// Più severo del pannello flottante, che si lascia sporgere per metà: il
    /// pannello lo hai messo lì tu e sai dov'è, mentre la mascotte ci finisce da
    /// sola quando scolleghi il monitor su cui stava.
    ///
    /// L'area visibile è quella *al netto* di menu bar e Dock: una mascotte
    /// sotto al Dock sarebbe raggiungibile solo spostando il Dock.
    public static func clamped(topLeft: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        // Uno schermo più piccolo della mascotte non ha un intervallo valido in
        // cui stare: si appoggia allora all'angolo in alto a sinistra, che è
        // l'unico da cui resta afferrabile.
        let minX = visible.minX
        let maxX = max(minX, visible.maxX - size.width)
        let maxY = visible.maxY
        let minY = min(maxY, visible.minY + size.height)

        return CGPoint(
            x: min(max(topLeft.x, minX), maxX),
            y: min(max(topLeft.y, minY), maxY)
        )
    }

    /// La posizione di partenza: in basso a destra, come richiesto, e anche
    /// l'angolo dove dà meno fastidio — le finestre di solito sono ancorate in
    /// alto a sinistra, e lì non c'è né la barra dei menu né il notch.
    public static func defaultTopLeft(size: CGSize, in visible: CGRect) -> CGPoint {
        clamped(
            topLeft: CGPoint(
                x: visible.maxX - size.width - margin,
                y: visible.minY + size.height + margin
            ),
            size: size,
            in: visible
        )
    }

    /// Da coordinate globali a coordinate *relative allo schermo*.
    ///
    /// Si salva il relativo e non il globale perché le coordinate globali di un
    /// monitor secondario dipendono da come i monitor sono disposti in
    /// Impostazioni di Sistema: sposta il monitor da destra a sinistra del
    /// portatile e ogni punto salvato indica un altro posto. Il relativo dice
    /// «in basso a destra di *quel* monitor», che è ciò che l'utente intendeva
    /// quando ce l'ha messa.
    public static func relative(topLeft: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: topLeft.x - screenFrame.minX, y: topLeft.y - screenFrame.minY)
    }

    /// L'inverso di `relative(topLeft:screenFrame:)`.
    public static func absolute(relativeTopLeft: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: relativeTopLeft.x + screenFrame.minX, y: relativeTopLeft.y + screenFrame.minY)
    }
}
