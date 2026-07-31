import Foundation

enum Format {
    /// Compact countdown: "4g 2h", "3h 12m", "8m", "42s", "ora".
    static func countdown(to date: Date, now: Date = Date()) -> String {
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
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.toNearestOrAwayFromZero)))%"
    }

    /// Relative age of a snapshot: "aggiornato ora", "2m fa", "1h 5m fa".
    static func age(since date: Date, now: Date = Date()) -> String {
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

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
