import Foundation

public enum Format {
    /// Compact countdown: "4g 2h", "3h 12m", "8m", "42s", "ora".
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "ora" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return hours > 0 ? "\(days)g \(hours)h" : "\(days)g" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// "0.174" → "17%". Rounds half-up and never shows 100% below the real cap.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.toNearestOrAwayFromZero)))%"
    }

    /// Relative age of a snapshot: "aggiornato ora", "2m fa", "1h 5m fa".
    public static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        if seconds < 10 { return "ora" }
        if seconds < 60 { return "\(seconds)s fa" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m fa" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 { return remainder > 0 ? "\(hours)h \(remainder)m fa" : "\(hours)h fa" }
        return "\(hours / 24)g fa"
    }

    public static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// L'ora di un messaggio in una chat.
    ///
    /// Tre forme, e il passaggio da una all'altra non è estetico: «due minuti fa»
    /// dice quello che serve sapere di un messaggio appena arrivato, ma «sette ore
    /// fa» costringe a fare un conto per sapere se era prima o dopo pranzo. Oltre
    /// l'ora conta *quando*, non *quanto tempo fa*. E oltre la mezzanotte conta
    /// anche il giorno, altrimenti «14:35» di ieri si legge come oggi.
    public static func messageTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())

        // Al futuro per pochi secondi si arriva con due orologi che non
        // concordano — quello del Mac e quello del telefono. Dire «fra un minuto»
        // sarebbe una spiegazione peggiore del silenzio.
        if seconds < 45 { return "adesso" }
        if seconds < 90 { return "un minuto fa" }
        if seconds < 3600 { return "\(seconds / 60) minuti fa" }

        let calendar = Calendar.current
        let time = clock.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        // «Ieri» rispetto a `now`, non rispetto al calendario di sistema:
        // `isDateInYesterday` guarda l'oggi vero e ignora l'adesso che ci è
        // stato passato, quindi sarebbe giusta solo quando i due coincidono —
        // cioè ovunque tranne che in una prova, che è dove serve saperlo.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "ieri \(time)"
        }
        return "\(dayMonth.string(from: date)), \(time)"
    }

    /// Quanto manca all'azzeramento di una finestra di utilizzo.
    ///
    /// Tre forme, e il confine è la leggibilità di un numero: «89:18:03» — che è
    /// ciò che un conto alla rovescia normale mostra per la finestra dei sette
    /// giorni — richiede una divisione a mente per sapere che sono tre giorni e
    /// mezzo. Oltre le ventiquattro ore quindi si contano i giorni, e le ore che
    /// restano oltre quelli.
    ///
    /// Testo fermo e non un cronometro: un cronometro di sistema sa contare solo
    /// in ore, minuti e secondi, ed è esattamente la forma che qui non serve.
    public static func resetDelay(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "adesso" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(max(1, minutes)) min" }

        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
        }

        let days = hours / 24
        let rest = hours % 24
        return rest > 0 ? "\(days)g \(rest)h" : "\(days)g"
    }

    /// Giorno e mese senza anno: in una chat che si legge sul telefono l'anno è
    /// rumore, e per il caso in cui servisse c'è la chat vera.
    public static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()
}
