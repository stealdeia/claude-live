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

    /// Where the Claude Code hooks drop one status file per session.
    static var statusDirectory: URL {
        home.appendingPathComponent(".claude-hub/status", isDirectory: true)
    }

    static func ensureDirectories() {
        for dir in [supportDirectory, logsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Created eagerly: FSEvents needs the directory to exist before the watcher
    /// starts, otherwise it watches a path that never resolves.
    static func ensureStatusDirectory() {
        try? FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
    }
}
