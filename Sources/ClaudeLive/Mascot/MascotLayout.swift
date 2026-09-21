import CoreGraphics
import SwiftUI
import MascotCore

/// Le misure della mascotte, in un posto solo.
///
/// Il pannello, il trascinamento e il riporto dentro lo schermo ragionano tutti
/// su `panelSize(barOpen:)`: cambiare le dimensioni del personaggio, o quelle
/// della barra, è un numero da toccare qui e basta.
enum MascotLayout {
    /// Il personaggio, alla dimensione a cui la pixel art resta leggibile.
    static let characterSize = CGSize(width: 96, height: 96)

    /// Larghezza di barra e fumetto.
    ///
    /// Larghi come il pannello flottante e non come il personaggio: in 96 punti
    /// non ci sta una frase. Non è un problema — la finestra è l'unione del
    /// personaggio e di quello che ha attorno, e i due possono essere sfalsati:
    /// vedi `MascotChromeLayout`.
    static let accessoryWidth: CGFloat = 268

    static let barFieldHeight: CGFloat = 32
    /// La riga sotto la barra che dice dove andrà a finire quello che scrivi.
    static let hintHeight: CGFloat = 16
    static let barRowHeight: CGFloat = barFieldHeight + 2 + hintHeight

    /// Il fumetto: righe da una riga sola, più i contorni e la punta.
    static let bubbleRow: CGFloat = 20
    static let bubbleTail: CGFloat = 7
    static let bubblePadding: CGFloat = 8
    /// Quante righe al massimo prima di «e altri N».
    static let bubbleMaxRows = 4
    /// Quante opzioni al massimo si offrono dentro il fumetto.
    static let bubbleMaxOptions = 3

    /// L'arancione di Claude.
    static let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)

    /// Quanto è alto il fumetto per quello che deve dire.
    static func bubbleHeight(for content: MascotBubbleContent) -> CGFloat {
        var rows: Int
        switch content {
        case .notice:
            rows = 1
        case .inbox(let items):
            rows = min(items.count, bubbleMaxRows)
            if items.count > bubbleMaxRows { rows += 1 }
            if items.count == 1, let item = items.first {
                if let question = item.questions.first {
                    rows += min(question.options.count, bubbleMaxOptions)
                } else if item.decidable {
                    rows += 1
                }
            }
        }
        return CGFloat(rows) * bubbleRow + 2 * bubblePadding + bubbleTail
    }

    /// Lo stacco fra il personaggio e quello che gli sta attorno.
    ///
    /// Generoso di proposito: attaccata, la barra sembra un pezzo del
    /// pupazzetto invece di una cosa che gli sta accanto.
    static let gap: CGFloat = 14

    static func chrome(bubble: MascotBubbleContent?, bar: Bool) -> MascotChrome {
        MascotChrome(
            bubbleHeight: bubble.map(bubbleHeight(for:)) ?? 0,
            barHeight: bar ? barRowHeight : 0,
            accessoryWidth: accessoryWidth,
            gap: gap
        )
    }
}
