import Foundation

/// One rate-limit window as reported by the `anthropic-ratelimit-unified-*` headers.
public struct UsageWindow: Codable, Equatable, Sendable {
    /// 0…1 (the header is a fraction, e.g. `0.17` for 17%).
    public var utilization: Double
    public var resetAt: Date?
    /// `allowed`, `allowed_warning`, `rejected`, …
    public var status: String?

    public var percent: Double { (utilization * 100).clamped(to: 0...100) }

    /// Spelled out because a public struct keeps its memberwise initialiser to
    /// itself, and the API client that builds these lives in another module.
    public init(utilization: Double, resetAt: Date?, status: String?) {
        self.utilization = utilization
        self.resetAt = resetAt
        self.status = status
    }
}

/// A complete reading of the account's limits at a point in time.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    /// Present only on plans with a separate Opus allowance.
    public var opusSevenDay: UsageWindow?
    /// Which window the API considers "the" limiting one (`five_hour` / `seven_day`).
    public var representativeClaim: String?
    public var overallStatus: String?
    public var fetchedAt: Date
    public var httpStatus: Int
    public var subscriptionType: String?

    /// True when the API answered 429 — still perfectly valid usage data.
    public var wasRateLimited: Bool { httpStatus == 429 }

    /// The number that goes in the menu bar: the 5h window is what people
    /// actually care about minute to minute.
    public var headlinePercent: Double? { fiveHour?.percent }

    /// Spelled out for the same reason as `UsageWindow`'s.
    public init(
        fiveHour: UsageWindow?,
        sevenDay: UsageWindow?,
        opusSevenDay: UsageWindow?,
        representativeClaim: String?,
        overallStatus: String?,
        fetchedAt: Date,
        httpStatus: Int,
        subscriptionType: String?
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.opusSevenDay = opusSevenDay
        self.representativeClaim = representativeClaim
        self.overallStatus = overallStatus
        self.fetchedAt = fetchedAt
        self.httpStatus = httpStatus
        self.subscriptionType = subscriptionType
    }
}

/// What the monitor is currently able to tell the UI.
public enum UsageState: Equatable, Sendable {
    /// Nothing fetched yet in this launch.
    case idle
    case refreshing
    /// Fresh data in hand.
    case live
    /// Request failed; `snapshot` (if any) is the last good reading.
    case stale(reason: StaleReason)
    /// Cannot even try: no usable credentials.
    case unavailable(message: String)

    public enum StaleReason: Equatable, Sendable {
        case offline
        case tokenExpired
        case httpError(Int)
        case other(String)

        public var message: String {
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
public enum UsageLevel: Sendable {
    case normal, warning, danger

    public static func level(for fraction: Double, warn: Double, danger: Double) -> UsageLevel {
        if fraction >= danger { return .danger }
        if fraction >= warn { return .warning }
        return .normal
    }
}
