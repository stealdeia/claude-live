import Foundation

/// What the Mac tells the phone.
///
/// A whole picture every time rather than a stream of changes. The phone can be
/// asleep, out of signal, or freshly launched, and a client that has to replay a
/// history to know the present is a client that can be subtly wrong for a long
/// time without anybody noticing. A snapshot is either current or visibly old.
public struct RemoteSnapshot: Codable, Equatable, Sendable {
    /// Bumped when the shape changes, so an old app meeting a new Mac says so
    /// instead of showing something plausible and wrong.
    public static let currentVersion = 1
    public var version: Int

    public var usage: UsageSnapshot?
    public var projects: [ClaudeProjectStatus]
    public var sessions: [ClaudeSessionStatus]
    /// The event worth lighting up for, if any.
    public var alert: ClaudeAlert?
    public var generatedAt: Date

    public init(
        version: Int = RemoteSnapshot.currentVersion,
        usage: UsageSnapshot?,
        projects: [ClaudeProjectStatus],
        sessions: [ClaudeSessionStatus],
        alert: ClaudeAlert?,
        generatedAt: Date
    ) {
        self.version = version
        self.usage = usage
        self.projects = projects
        self.sessions = sessions
        self.alert = alert
        self.generatedAt = generatedAt
    }
}

/// What the phone asks the Mac to do.
///
/// Every case carries the id of the thing it acts on, never an index or a
/// position: by the time a command lands, the list it was chosen from may have
/// moved on, and acting on "the second one" would act on the wrong thing.
public enum RemoteCommand: Codable, Equatable, Sendable {
    /// Answer a permission request the hook is blocked on.
    case decide(requestID: String, allow: Bool, remember: Bool)

    /// Send a prompt to a session. Reserved: no supported way to inject input
    /// into a live session exists yet, so nothing sends this today.
    case prompt(sessionID: String, text: String)
}

/// A command with enough context to be judged before it is obeyed.
public struct RemoteCommandEnvelope: Codable, Equatable, Sendable {
    public var command: RemoteCommand
    /// Distinct per command, so a replayed or duplicated delivery can be
    /// recognised rather than carried out twice — which for "allow" would mean
    /// approving something the user approved once.
    public var id: String
    public var issuedAt: Date

    public init(command: RemoteCommand, id: String = UUID().uuidString, issuedAt: Date = Date()) {
        self.command = command
        self.id = id
        self.issuedAt = issuedAt
    }

    /// A command older than this is refused rather than obeyed late.
    ///
    /// The phone may have been offline when it was issued, and a permission
    /// granted twenty minutes ago answers a question nobody is asking any more.
    public static let maximumAge: TimeInterval = 120

    public func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        // Also rejects the future: a phone whose clock runs ahead would
        // otherwise mint commands that never expire.
        return age >= -30 && age <= Self.maximumAge
    }
}
