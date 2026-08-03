import Foundation

/// Every file this app owns lives under ~/Library/Application Support/ClaudeHub/.
/// Nothing is ever written outside of it (with the single exception of the
/// Claude Code settings.json patch in Phase 3, which is explicit and opt-in).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var supportDirectory: URL {
        home
            .appendingPathComponent("Library/Application Support/ClaudeHub", isDirectory: true)
    }

    static var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    /// Last known usage snapshot, so a cold start can show data immediately
    /// (clearly stamped as stale) before the first network round trip lands.
    static var usageCacheFile: URL {
        supportDirectory.appendingPathComponent("usage-cache.json")
    }

    static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    static var logFile: URL {
        logsDirectory.appendingPathComponent("claudelive.log")
    }

    /// Shared with the Claude Code hooks.
    static var hubDirectory: URL {
        home.appendingPathComponent(".claude-hub", isDirectory: true)
    }

    /// Where the Claude Code hooks drop one status file per session.
    static var statusDirectory: URL {
        hubDirectory.appendingPathComponent("status", isDirectory: true)
    }

    /// Where the app drops its answers to permission requests; the hook polls here.
    static var decisionsDirectory: URL {
        hubDirectory.appendingPathComponent("decisions", isDirectory: true)
    }

    /// Touched periodically so the hook can tell whether the app is running — it
    /// only waits for an answer when there is someone to give one.
    static var heartbeatFile: URL {
        hubDirectory.appendingPathComponent("app-heartbeat")
    }

    /// Settings the hook needs to read, chiefly how long to wait for an answer.
    static var hubConfigFile: URL {
        hubDirectory.appendingPathComponent("config.json")
    }

    /// Requests the user chose to always allow, written by the hook.
    static var allowlistFile: URL {
        hubDirectory.appendingPathComponent("allowlist.json")
    }

    static func ensureDirectories() {
        for dir in [supportDirectory, logsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Created eagerly: FSEvents needs the directory to exist before the watcher
    /// starts, otherwise it watches a path that never resolves.
    static func ensureStatusDirectory() {
        for dir in [statusDirectory, decisionsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
