import Foundation

/// Material for previews and tests.
///
/// Lives in the package rather than in the app so the SwiftUI canvas and the
/// test suite exercise the same shapes: a preview built on hand-made data that
/// no test ever sees is a preview that can drift away from what the app will
/// really be handed.
///
/// The timestamps are fixed rather than relative to now, so a snapshot never
/// renders differently depending on when it is looked at.
extension RemoteSnapshot {

    /// A moment worth designing for: one project blocked on a permission,
    /// another working, a third quietly idle.
    public static func sample(now: Date = Date(timeIntervalSince1970: 1_787_000_000)) -> RemoteSnapshot {
        let blocked = ClaudeSessionStatus(json: [
            "project_path": "/Users/s/Progetti/claude-live",
            "project_name": "claude-live",
            "session_id": "a1b2c3d4e5f6",
            "state": "waiting_input",
            "event": "PermissionRequest",
            "request_kind": "permission",
            "request_id": "toolu_01",
            "tool_name": "Bash",
            "tool_summary": "rm -rf build && ./build.sh",
            "decidable": true,
            "updated_at_epoch": now.timeIntervalSince1970 - 6,
        ])!

        let question = ClaudeSessionStatus(json: [
            "project_path": "/Users/s/Progetti/claude-live",
            "project_name": "claude-live",
            "session_id": "99887766aabb",
            "cwd": "/Users/s/Progetti/claude-live/relay",
            "state": "waiting_input",
            "event": "Notification",
            "request_kind": "notification",
            "detail": "Quale dei due approcci preferisci?",
            "decidable": false,
            "updated_at_epoch": now.timeIntervalSince1970 - 95,
        ])!

        let working = ClaudeSessionStatus(json: [
            "project_path": "/Users/s/Progetti/sito-aldeialab",
            "project_name": "sito-aldeialab",
            "session_id": "77aa11bb22cc",
            "state": "working",
            "event": "PreToolUse",
            "detail": "Edit",
            "tool_name": "Edit",
            "decidable": false,
            "updated_at_epoch": now.timeIntervalSince1970 - 2,
        ])!

        let idle = ClaudeSessionStatus(json: [
            "project_path": "/Users/s/Progetti/appunti",
            "project_name": "appunti",
            "session_id": "deadbeef0011",
            "state": "idle",
            "event": "Stop",
            "decidable": false,
            "updated_at_epoch": now.timeIntervalSince1970 - 1_800,
        ])!

        return RemoteSnapshot(
            usage: UsageSnapshot(
                fiveHour: UsageWindow(
                    utilization: 0.78,
                    resetAt: now.addingTimeInterval(2 * 3_600 + 12 * 60),
                    status: "allowed_warning"
                ),
                sevenDay: UsageWindow(
                    utilization: 0.41,
                    resetAt: now.addingTimeInterval(4 * 86_400),
                    status: "allowed"
                ),
                opusSevenDay: UsageWindow(
                    utilization: 0.22,
                    resetAt: now.addingTimeInterval(4 * 86_400),
                    status: "allowed"
                ),
                representativeClaim: "five_hour",
                overallStatus: "allowed_warning",
                fetchedAt: now.addingTimeInterval(-40),
                httpStatus: 200,
                subscriptionType: "max"
            ),
            projects: [
                ClaudeProjectStatus(
                    projectPath: "/Users/s/Progetti/claude-live",
                    state: .waitingInput,
                    detail: "Bash",
                    requestKind: "permission",
                    updatedAt: now.addingTimeInterval(-6),
                    sessionCount: 2,
                    isStale: false
                ),
                ClaudeProjectStatus(
                    projectPath: "/Users/s/Progetti/sito-aldeialab",
                    state: .working,
                    detail: "Edit",
                    requestKind: nil,
                    updatedAt: now.addingTimeInterval(-2),
                    sessionCount: 1,
                    isStale: false
                ),
                ClaudeProjectStatus(
                    projectPath: "/Users/s/Progetti/appunti",
                    state: .idle,
                    detail: nil,
                    requestKind: nil,
                    updatedAt: now.addingTimeInterval(-1_800),
                    sessionCount: 1,
                    isStale: false
                ),
            ],
            sessions: [blocked, question, working, idle],
            alert: ClaudeAlert(
                kind: .waiting,
                projectPath: "/Users/s/Progetti/claude-live",
                projectName: "claude-live",
                sessionID: "a1b2c3d4e5f6",
                raisedAt: now.addingTimeInterval(-6),
                detail: "rm -rf build && ./build.sh"
            ),
            generatedAt: now
        )
    }

    /// Nothing happening: the state the app spends most of its life in, and the
    /// one most easily forgotten when designing against a busy screen.
    public static func sampleQuiet(now: Date = Date(timeIntervalSince1970: 1_787_000_000)) -> RemoteSnapshot {
        RemoteSnapshot(
            usage: UsageSnapshot(
                fiveHour: UsageWindow(utilization: 0.09, resetAt: now.addingTimeInterval(4 * 3_600), status: "allowed"),
                sevenDay: UsageWindow(utilization: 0.15, resetAt: now.addingTimeInterval(5 * 86_400), status: "allowed"),
                opusSevenDay: nil,
                representativeClaim: "five_hour",
                overallStatus: "allowed",
                fetchedAt: now.addingTimeInterval(-20),
                httpStatus: 200,
                subscriptionType: "max"
            ),
            projects: [],
            sessions: [],
            alert: nil,
            generatedAt: now
        )
    }
}
