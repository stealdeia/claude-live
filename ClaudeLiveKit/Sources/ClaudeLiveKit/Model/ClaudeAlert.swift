import Foundation

/// Something that happened in a project and that the user has not acknowledged yet.
///
/// This is a different thing from `ClaudeActivity`, and the difference is the whole
/// point. Activity is a *state*: what a session is doing right now, recomputed from
/// disk every few seconds. An alert is an *event*: it is raised by a transition, it
/// outlives the state that caused it, and it goes away when the user has seen it —
/// which is what a notification signal has to be. "Claude ha finito" is invisible
/// as a state, because a finished session and a session that just opened are both
/// `idle`; it only exists as the transition into it.
public enum ClaudeAlertKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Claude is waiting for an answer: a permission, a question, a choice.
    case waiting
    /// A turn ended normally.
    case done
    /// A turn died on an error, or a working session went silent.
    case failed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .waiting: return "Claude chiede qualcosa"
        case .done: return "Claude ha finito"
        case .failed: return "Claude si è interrotto"
        }
    }

    /// Ranking for the one case the strip cannot express: several projects with
    /// different alerts at the same time. One light, so the most serious wins.
    public var urgency: Int {
        switch self {
        case .failed: return 3
        case .waiting: return 2
        case .done: return 1
        }
    }

    public var defaultColor: GlowRGB {
        switch self {
        case .waiting: return .waiting
        case .done: return .done
        case .failed: return .failed
        }
    }

    /// Title of the macOS notification, which names the project.
    public func notificationTitle(project: String) -> String {
        switch self {
        case .waiting: return "Claude ti aspetta in \(project)"
        case .done: return "Claude ha finito in \(project)"
        case .failed: return "Claude si è interrotto in \(project)"
        }
    }
}

public struct ClaudeAlert: Equatable, Sendable {
    public let kind: ClaudeAlertKind
    public let projectPath: String
    public let projectName: String
    /// The session that raised it, so the panel can light *that* chat and not just
    /// the project. Nil only if the group was empty by the time we looked.
    public let sessionID: String?
    public let raisedAt: Date
    /// The tool being run, the error, the kind of request — whatever the status
    /// file carried at the moment of the transition.
    public let detail: String?

    /// Spelled out because a public struct keeps its memberwise initialiser to
    /// itself, and the store that raises these lives in another module.
    public init(
        kind: ClaudeAlertKind,
        projectPath: String,
        projectName: String,
        sessionID: String?,
        raisedAt: Date,
        detail: String?
    ) {
        self.kind = kind
        self.projectPath = projectPath
        self.projectName = projectName
        self.sessionID = sessionID
        self.raisedAt = raisedAt
        self.detail = detail
    }

    /// Most serious first, then most recent: the order the strip and the panel
    /// both need.
    public static func moreUrgent(_ lhs: ClaudeAlert, _ rhs: ClaudeAlert) -> Bool {
        lhs.kind.urgency == rhs.kind.urgency
            ? lhs.raisedAt > rhs.raisedAt
            : lhs.kind.urgency > rhs.kind.urgency
    }
}

/// Transmissible, so the phone can light up for the same event the notch does.
extension ClaudeAlert: Codable {}
