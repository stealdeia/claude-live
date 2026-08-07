import Foundation

/// One rate-limit window as reported by the `anthropic-ratelimit-unified-*` headers.
struct UsageWindow: Codable, Equatable {
    /// 0…1 (the header is a fraction, e.g. `0.17` for 17%).
    var utilization: Double
    var resetAt: Date?
    /// `allowed`, `allowed_warning`, `rejected`, …
    var status: String?

    var percent: Double { (utilization * 100).clamped(to: 0...100) }
}

/// A complete reading of the account's limits at a point in time.
struct UsageSnapshot: Codable, Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    /// Present only on plans with a separate Opus allowance.
    var opusSevenDay: UsageWindow?
    /// Which window the API considers "the" limiting one (`five_hour` / `seven_day`).
    var representativeClaim: String?
    var overallStatus: String?
    var fetchedAt: Date
    var httpStatus: Int
    var subscriptionType: String?

    /// True when the API answered 429 — still perfectly valid usage data.
    var wasRateLimited: Bool { httpStatus == 429 }

    /// The number that goes in the menu bar: the 5h window is what people
    /// actually care about minute to minute.
    var headlinePercent: Double? { fiveHour?.percent }
}

/// What the monitor is currently able to tell the UI.
enum UsageState: Equatable {
    /// Nothing fetched yet in this launch.
    case idle
    case refreshing
    /// Fresh data in hand.
    case live
    /// Request failed; `snapshot` (if any) is the last good reading.
    case stale(reason: StaleReason)
    /// Cannot even try: no usable credentials.
    case unavailable(message: String)

    enum StaleReason: Equatable {
        case offline
        case tokenExpired
        case httpError(Int)
        case other(String)

        var message: String {
            switch self {
            case .offline:
                return "Nessuna connessione"
            case .tokenExpired:
                // Reached only when the API itself refused the token, so the wording
                // says what to do rather than guessing at a cause.
                return "Token scaduto: usa Claude Code e mi riprendo da solo"
            case .httpError(let code):
                return "Errore HTTP \(code)"
            case .other(let text):
                return text
            }
        }
    }
}

/// Severity used to colour bars, the menu bar icon and notifications.
enum UsageLevel {
    case normal, warning, danger

    static func level(for fraction: Double, warn: Double, danger: Double) -> UsageLevel {
        if fraction >= danger { return .danger }
        if fraction >= warn { return .warning }
        return .normal
    }
}
