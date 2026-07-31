import Foundation

/// What Claude Code is doing in a project.
enum ClaudeActivity: String, Codable, Comparable {
    /// A prompt is being worked on.
    case working
    /// Waiting for the user: a permission request or a question.
    case waitingInput
    /// The turn ended with an API error.
    case error
    /// Session open, nothing running.
    case idle
    /// The status file went quiet while it claimed to be working.
    case unknown

    /// Ordering by urgency: the most urgent wins when a project has several
    /// concurrent sessions, and drives sorting in the panel.
    private var urgency: Int {
        switch self {
        case .waitingInput: return 4
        case .error: return 3
        case .working: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    static func < (lhs: ClaudeActivity, rhs: ClaudeActivity) -> Bool {
        lhs.urgency < rhs.urgency
    }

    var label: String {
        switch self {
        case .working: return "al lavoro"
        case .waitingInput: return "attende input"
        case .error: return "errore"
        case .idle: return "in attesa"
        case .unknown: return "sconosciuto"
        }
    }
}

/// One status file, as written by the hook script.
struct ClaudeSessionStatus: Identifiable, Equatable {
    let projectPath: String
    let projectName: String
    let sessionID: String
    let state: ClaudeActivity
    /// Tool name, notification message or error type, depending on the event.
    let detail: String?
    /// `permission`, `notification`, a notification type, …
    let requestKind: String?
    let event: String
    let permissionMode: String?
    let updatedAt: Date

    var id: String { "\(projectPath)#\(sessionID)" }

    /// Decoded by hand: the file is written by a Python hook with snake_case
    /// keys, and being lenient about missing or extra fields means a future
    /// hook version can add data without breaking this reader.
    init?(json: [String: Any]) {
        guard let projectPath = json["project_path"] as? String, !projectPath.isEmpty else {
            return nil
        }
        guard let rawState = json["state"] as? String else { return nil }

        self.projectPath = projectPath
        self.projectName = (json["project_name"] as? String)
            ?? (projectPath as NSString).lastPathComponent
        self.sessionID = (json["session_id"] as? String) ?? "unknown"

        // `waiting_input` in the file, `waitingInput` in Swift.
        switch rawState {
        case "working": state = .working
        case "waiting_input": state = .waitingInput
        case "error": state = .error
        case "idle": state = .idle
        default: state = .unknown
        }

        let rawDetail = (json["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = (rawDetail?.isEmpty == false) ? rawDetail : nil
        requestKind = json["request_kind"] as? String
        event = (json["event"] as? String) ?? ""
        permissionMode = json["permission_mode"] as? String

        if let epoch = json["updated_at_epoch"] as? Double {
            updatedAt = Date(timeIntervalSince1970: epoch)
        } else {
            updatedAt = Date()
        }
    }

    private init(
        projectPath: String,
        projectName: String,
        sessionID: String,
        state: ClaudeActivity,
        detail: String?,
        requestKind: String?,
        event: String,
        permissionMode: String?,
        updatedAt: Date
    ) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.sessionID = sessionID
        self.state = state
        self.detail = detail
        self.requestKind = requestKind
        self.event = event
        self.permissionMode = permissionMode
        self.updatedAt = updatedAt
    }

    /// Re-attributes this session to the deepest known project that contains it.
    ///
    /// The hook can only resolve a git root; a session started in a subdirectory
    /// of a non-git project would otherwise look like a project of its own.
    /// `candidates` are the workspace roots VS Code knows about.
    func movedToProjectRoot(among candidates: [String]) -> ClaudeSessionStatus {
        var best: String?
        for candidate in candidates {
            guard projectPath == candidate || projectPath.hasPrefix(candidate + "/") else { continue }
            if best == nil || candidate.count > best!.count { best = candidate }
        }

        guard let root = best, root != projectPath else { return self }

        return ClaudeSessionStatus(
            projectPath: root,
            projectName: (root as NSString).lastPathComponent,
            sessionID: sessionID,
            state: state,
            detail: detail,
            requestKind: requestKind,
            event: event,
            permissionMode: permissionMode,
            updatedAt: updatedAt
        )
    }
}

/// The aggregate status of one project, across all of its Claude Code sessions.
struct ClaudeProjectStatus: Equatable {
    let projectPath: String
    let state: ClaudeActivity
    let detail: String?
    let requestKind: String?
    let updatedAt: Date
    let sessionCount: Int
    /// True when we downgraded a `working` record that had gone quiet.
    let isStale: Bool

    /// A short badge for the panel row: the kind of thing being awaited, or the
    /// tool currently running.
    var badge: String? {
        switch state {
        case .waitingInput:
            switch requestKind {
            case "permission": return "permesso"
            case "input", "notification", .none: return "input"
            case .some(let kind): return kind.replacingOccurrences(of: "_", with: " ")
            }
        case .working:
            return detail
        case .error:
            return detail ?? "errore"
        case .idle, .unknown:
            return nil
        }
    }

    var tooltip: String {
        var lines = ["Claude Code: \(state.label)\(isStale ? " (dato vecchio)" : "")"]
        if let detail { lines.append(detail) }
        if sessionCount > 1 { lines.append("\(sessionCount) sessioni") }
        lines.append("aggiornato \(Format.age(since: updatedAt))")
        return lines.joined(separator: "\n")
    }
}
