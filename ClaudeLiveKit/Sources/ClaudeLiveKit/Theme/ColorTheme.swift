import SwiftUI

/// La tavolozza dell'app, come dato.
///
/// Nel Kit e non in una delle due app perché sono gli stessi temi su entrambe: se
/// vivessero nell'app iPhone, il Mac ne avrebbe una copia, e due copie di una
/// tavolozza divergono al primo colore ritoccato in un posto solo.
///
/// Il Mac li usa più smorzati del telefono: là il colore riempie lo schermo, qui
/// deve arrivare in fondo a un pannello il cui bordo superiore deve restare nero
/// per confondersi col ritaglio del MacBook.
///
/// A theme is a list of colours and nothing else — no view knows the name of a
/// particular one. That is what makes adding a new one later a matter of one
/// entry in `all`, which is the point: the plan is to hand out new looks over
/// time the way Revolut does with its card skins.
public struct ColorTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    /// The top of the screen. Black on purpose, so the background meets the
    /// Dynamic Island and the two stop being distinguishable — the phone's own
    /// hardware becomes the top edge of the app.
    public let top: Color
    /// Where the colour arrives, at the bottom.
    public let deep: Color
    /// The bloom in the middle, which is what stops it reading as a plain fade.
    public let bloom: Color
    /// For the elements that have to stand out against all of it.
    public let accent: Color

    public init(id: String, name: String, top: Color, deep: Color, bloom: Color, accent: Color) {
        self.id = id
        self.name = name
        self.top = top
        self.deep = deep
        self.bloom = bloom
        self.accent = accent
    }

    public static let midnight = ColorTheme(
        id: "midnight",
        name: "Mezzanotte",
        top: Color(red: 0.02, green: 0.02, blue: 0.04),
        deep: Color(red: 0.05, green: 0.11, blue: 0.30),
        bloom: Color(red: 0.09, green: 0.18, blue: 0.42),
        accent: Color(red: 0.38, green: 0.62, blue: 1.00)
    )

    /// The house colour: the project ships under the Purple Heads name.
    public static let purpleHeart = ColorTheme(
        id: "purpleHeart",
        name: "Purple Heart",
        top: Color(red: 0.03, green: 0.02, blue: 0.05),
        deep: Color(red: 0.20, green: 0.06, blue: 0.34),
        bloom: Color(red: 0.32, green: 0.11, blue: 0.48),
        accent: Color(red: 0.78, green: 0.52, blue: 1.00)
    )

    public static let ember = ColorTheme(
        id: "ember",
        name: "Brace",
        top: Color(red: 0.04, green: 0.02, blue: 0.02),
        deep: Color(red: 0.30, green: 0.08, blue: 0.05),
        bloom: Color(red: 0.46, green: 0.16, blue: 0.06),
        accent: Color(red: 1.00, green: 0.60, blue: 0.35)
    )

    public static let forest = ColorTheme(
        id: "forest",
        name: "Bosco",
        top: Color(red: 0.02, green: 0.03, blue: 0.03),
        deep: Color(red: 0.04, green: 0.22, blue: 0.16),
        bloom: Color(red: 0.06, green: 0.32, blue: 0.24),
        accent: Color(red: 0.40, green: 0.92, blue: 0.68)
    )

    /// Nero pieno: il pannello com'era prima dei temi.
    ///
    /// Non è un tema come gli altri, è la loro assenza — `deep` e `bloom` neri
    /// rendono invisibile il colore che scende, e resta il nero opaco di sempre.
    /// L'accento serve comunque, perché qualcosa deve pur risaltare.
    public static let black = ColorTheme(
        id: "black",
        name: "Nero",
        top: .black,
        deep: .black,
        bloom: .black,
        accent: Color(red: 0.38, green: 0.62, blue: 1.00)
    )

    public static let all: [ColorTheme] = [.midnight, .purpleHeart, .ember, .forest]

    /// Le scelte per il pannello del Mac: il nero e tutti gli altri.
    ///
    /// Elenco a parte perché sul telefono il tema riempie l'intero schermo, e
    /// «tutto nero» lì è una proposta diversa — uno sfondo nero e piatto, non un
    /// pannello che si confonde con l'hardware. Sul Mac invece è il
    /// comportamento di prima, e chi lo preferiva deve poterlo riavere.
    public static let panelChoices: [ColorTheme] = [.black] + all
}

extension ColorTheme {
    /// Il colore che scende verso il basso del pannello, da mettere **sopra** una
    /// base nera opaca.
    ///
    /// Qui e non nella vista perché lo usano in due: il pannello vero e
    /// l'anteprima nelle impostazioni. Due copie della stessa formula
    /// divergerebbero al primo ritocco, e a quel punto l'anteprima mentirebbe —
    /// che è peggio che non averla.
    ///
    /// Va messo sopra il nero e non usato come riempimento: un gradiente
    /// semitrasparente renderebbe traslucida la finestra, e il pannello
    /// smetterebbe di leggersi come un prolungamento del ritaglio del MacBook.
    ///
    /// `blackUntil` è la frazione di altezza che resta nera: la striscia sempre
    /// visibile. Da chiuso è tutta la superficie, quindi il colore non si vede.
    public func panelWash(blackUntil: CGFloat) -> LinearGradient {
        let start = min(max(blackUntil, 0), 1)
        let span = 1 - start
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: start),
                .init(color: bloom.opacity(0.45), location: start + span * 0.42),
                .init(color: deep.opacity(0.74), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
