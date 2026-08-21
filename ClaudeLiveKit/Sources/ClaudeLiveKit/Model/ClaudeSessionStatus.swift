import Foundation

/// What Claude Code is doing in a project.
public enum ClaudeActivity: String, Codable, Comparable, Sendable {
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

    public static func < (lhs: ClaudeActivity, rhs: ClaudeActivity) -> Bool {
        lhs.urgency < rhs.urgency
    }

    public var label: String {
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
public struct ClaudeSessionStatus: Identifiable, Equatable, Sendable {
    public let projectPath: String
    public let projectName: String
    public let sessionID: String
    public let state: ClaudeActivity
    /// Directory `claude` was launched from. Often the project root, but not
    /// always — it is what tells two chats in the same project apart.
    public let cwd: String?
    /// Tool name, notification message or error type, depending on the event.
    public let detail: String?
    /// `permission`, `notification`, a notification type, …
    public let requestKind: String?
    public let event: String
    public let permissionMode: String?
    public let updatedAt: Date
    /// True when the record claimed to be busy but stopped being refreshed, so
    /// its state was downgraded rather than trusted. See `ClaudeStatusStore`.
    public let isStale: Bool

    /// Identifier of the permission request the hook is blocked on, if any.
    public let requestID: String?
    public let toolName: String?
    /// One readable line describing what Claude wants to do.
    public let toolSummary: String?
    /// True while the hook is actually waiting for an answer from this app, so
    /// showing Allow/Deny buttons can lead somewhere.
    public let decidable: Bool

    /// The tail of what Claude last said, when the hook was able to read it.
    ///
    /// Optional and often nil: the hook receives `transcript_path` on every
    /// event, but reading it is a separate decision from reporting a state, and
    /// it is the first thing in this system that carries the *content* of a
    /// conversation rather than a fact about it. Nil means "not read", never
    /// "said nothing".
    public let lastMessage: String?

    /// Il titolo che Claude Code dà a questa chat, quello che si legge sopra la
    /// conversazione.
    ///
    /// Non arriva dall'hook: Claude Code lo scrive nella trascrizione della
    /// sessione e l'app lo va a leggere. `nil` finché non è stato trovato — una
    /// chat appena aperta non ne ha ancora uno.
    public let chatTitle: String?

    public var id: String { "\(projectPath)#\(sessionID)" }

    /// Enough of the session id to tell two chats apart in a row.
    public var shortSessionID: String { String(sessionID.prefix(6)) }

    /// Label for one chat inside a project: the subdirectory it was started in
    /// when that differs from the project root — the only thing the hook gives us
    /// that a human recognises — and the short session id otherwise.
    public var chatLabel: String {
        // Il titolo di Claude Code quando c'è: è quello che l'utente legge sopra
        // la conversazione, quindi è l'unico nome con cui riconosce una chat.
        if let chatTitle, !chatTitle.isEmpty { return chatTitle }

        if let cwd, !cwd.isEmpty, cwd != projectPath {
            if cwd.hasPrefix(projectPath + "/") {
                let relative = String(cwd.dropFirst(projectPath.count + 1))
                if !relative.isEmpty { return relative }
            } else {
                let leaf = (cwd as NSString).lastPathComponent
                if !leaf.isEmpty { return leaf }
            }
        }
        return "chat \(shortSessionID)"
    }

    /// One line for the chat row: what this session is doing, in words.
    public var activityLabel: String {
        switch state {
        case .working: return detail.map { "al lavoro · \($0)" } ?? "al lavoro"
        case .waitingInput: return detail ?? requestKind ?? "attende una risposta"
        case .error: return detail.map { "errore · \($0)" } ?? "errore"
        case .idle: return "in attesa"
        case .unknown: return isStale ? "nessun aggiornamento" : "sconosciuto"
        }
    }

    public var tooltip: String {
        var lines = ["Claude Code: \(state.label)\(isStale ? " (dato vecchio)" : "")"]
        if let detail { lines.append(detail) }
        if let cwd, !cwd.isEmpty { lines.append(cwd) }
        lines.append("sessione \(sessionID)")
        lines.append("aggiornato \(Format.age(since: updatedAt))")
        return lines.joined(separator: "\n")
    }

    /// A permission request this app can answer.
    public var isDecidable: Bool {
        decidable && state == .waitingInput && !(requestID ?? "").isEmpty
    }

    /// Waiting on the user, but not something we can answer — an open question,
    /// so the only useful action is to bring its window forward.
    public var needsTerminal: Bool {
        state == .waitingInput && !isDecidable
    }

    /// Decoded by hand: the file is written by a Python hook with snake_case keys,
    /// and being lenient about missing or extra fields means an older hook keeps
    /// working after the app is updated, and vice versa.
    public init?(json: [String: Any]) {
        guard let projectPath = json["project_path"] as? String, !projectPath.isEmpty else {
            return nil
        }
        guard let rawState = json["state"] as? String else { return nil }

        self.projectPath = projectPath
        self.projectName = (json["project_name"] as? String)
            ?? (projectPath as NSString).lastPathComponent
        self.sessionID = (json["session_id"] as? String) ?? "unknown"
        let rawCwd = (json["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        cwd = (rawCwd?.isEmpty == false) ? rawCwd : nil
        // Never stale as written: only the store, which knows the clock, decides.
        isStale = false

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

        let rawRequestID = (json["request_id"] as? String) ?? ""
        requestID = rawRequestID.isEmpty ? nil : rawRequestID
        toolName = json["tool_name"] as? String
        let rawSummary = (json["tool_summary"] as? String)?.trimmingCharacters(in: .whitespaces)
        toolSummary = (rawSummary?.isEmpty == false) ? rawSummary : nil
        decidable = (json["decidable"] as? Bool) ?? false

        let rawMessage = (json["last_message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastMessage = (rawMessage?.isEmpty == false) ? rawMessage : nil

        let rawTitle = (json["chat_title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        chatTitle = (rawTitle?.isEmpty == false) ? rawTitle : nil

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
        cwd: String?,
        isStale: Bool,
        detail: String?,
        requestKind: String?,
        event: String,
        permissionMode: String?,
        updatedAt: Date,
        requestID: String?,
        toolName: String?,
        toolSummary: String?,
        lastMessage: String?,
        decidable: Bool,
        chatTitle: String? = nil
    ) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.sessionID = sessionID
        self.state = state
        self.cwd = cwd
        self.isStale = isStale
        self.detail = detail
        self.requestKind = requestKind
        self.event = event
        self.permissionMode = permissionMode
        self.updatedAt = updatedAt
        self.requestID = requestID
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.lastMessage = lastMessage
        self.decidable = decidable
        self.chatTitle = chatTitle
    }

    /// Re-attributes this session to the deepest known project that contains it.
    ///
    /// The hook can only resolve a git root; a session started in a subdirectory
    /// of a non-git project would otherwise look like a project of its own.
    /// `candidates` are the workspace roots VS Code knows about.
    public func movedToProjectRoot(among candidates: [String]) -> ClaudeSessionStatus {
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
            cwd: cwd,
            isStale: isStale,
            detail: detail,
            requestKind: requestKind,
            event: event,
            permissionMode: permissionMode,
            updatedAt: updatedAt,
            requestID: requestID,
            toolName: toolName,
            toolSummary: toolSummary,
            lastMessage: lastMessage,
            decidable: decidable,
            chatTitle: chatTitle
        )
    }
}

extension ClaudeSessionStatus {
    /// La stessa sessione con il titolo che Claude Code le ha dato.
    ///
    /// Applicato dopo il caricamento e non decodificato: il titolo vive nella
    /// trascrizione della sessione, non nel file di stato che scrive l'hook, e
    /// leggerlo è lavoro dell'app.
    public func withChatTitle(_ title: String?) -> ClaudeSessionStatus {
        guard let title, !title.isEmpty, title != chatTitle else { return self }
        return ClaudeSessionStatus(
            projectPath: projectPath,
            projectName: projectName,
            sessionID: sessionID,
            state: state,
            cwd: cwd,
            isStale: isStale,
            detail: detail,
            requestKind: requestKind,
            event: event,
            permissionMode: permissionMode,
            updatedAt: updatedAt,
            requestID: requestID,
            toolName: toolName,
            toolSummary: toolSummary,
            lastMessage: lastMessage,
            decidable: decidable,
            chatTitle: title
        )
    }

    /// Same session with its state replaced, for the store's "claimed to be busy
    /// but stopped reporting" downgrade. `isStale` records that it happened, so a
    /// row can say so instead of silently showing something else.
    public func downgraded(to state: ClaudeActivity) -> ClaudeSessionStatus {
        ClaudeSessionStatus(
            projectPath: projectPath,
            projectName: projectName,
            sessionID: sessionID,
            state: state,
            cwd: cwd,
            isStale: true,
            detail: detail,
            requestKind: requestKind,
            event: event,
            permissionMode: permissionMode,
            updatedAt: updatedAt,
            requestID: requestID,
            toolName: toolName,
            toolSummary: toolSummary,
            lastMessage: lastMessage,
            decidable: decidable,
            chatTitle: chatTitle
        )
    }
}

/// The aggregate status of one project, across all of its Claude Code sessions.
public struct ClaudeProjectStatus: Equatable, Sendable {
    public let projectPath: String
    public let state: ClaudeActivity
    public let detail: String?
    public let requestKind: String?
    public let updatedAt: Date
    public let sessionCount: Int
    /// True when we downgraded a `working` record that had gone quiet.
    public let isStale: Bool

    /// Spelled out because a public struct keeps its memberwise initialiser to
    /// itself, and the store that aggregates these lives in another module.
    public init(
        projectPath: String,
        state: ClaudeActivity,
        detail: String?,
        requestKind: String?,
        updatedAt: Date,
        sessionCount: Int,
        isStale: Bool
    ) {
        self.projectPath = projectPath
        self.state = state
        self.detail = detail
        self.requestKind = requestKind
        self.updatedAt = updatedAt
        self.sessionCount = sessionCount
        self.isStale = isStale
    }

    /// A short badge for the panel row: the kind of thing being awaited, or the
    /// tool currently running.
    public var badge: String? {
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

    public var tooltip: String {
        var lines = ["Claude Code: \(state.label)\(isStale ? " (dato vecchio)" : "")"]
        if let detail { lines.append(detail) }
        if sessionCount > 1 { lines.append("\(sessionCount) sessioni") }
        lines.append("aggiornato \(Format.age(since: updatedAt))")
        return lines.joined(separator: "\n")
    }
}

/// Transmissible, for the iPhone companion.
///
/// Being sendable over a wire is not something the panel ever needed: it is a
/// consequence of there being a second device. Synthesised — every stored
/// property is a `String`, `Date`, `Bool` or an enum that codes itself.
extension ClaudeSessionStatus: Codable {}
extension ClaudeProjectStatus: Codable {}
