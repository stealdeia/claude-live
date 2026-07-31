import Foundation
import os

/// Dual-sink logger: always to the unified system log (visible in Console.app
/// and `log stream`), and — when debug logging is enabled in settings — also to
/// a plain text file that is easy to tail and to paste into a bug report.
enum Log {
    enum Category: String {
        case app, usage, keychain, panel, projects, status
    }

    private static let subsystem = "it.aldeialab.ClaudeLive"

    private static var loggers: [Category: os.Logger] = [:]
    private static let loggerLock = NSLock()

    private static let fileQueue = DispatchQueue(label: "it.aldeialab.ClaudeLive.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Mirrored from settings so logging never has to touch the main actor.
    static var fileLoggingEnabled: Bool = false

    private static func logger(for category: Category) -> os.Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let existing = loggers[category] { return existing }
        let made = os.Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category] = made
        return made
    }

    static func debug(_ message: String, category: Category = .app) {
        logger(for: category).debug("\(message, privacy: .public)")
        appendToFile("DEBUG", category, message)
    }

    static func info(_ message: String, category: Category = .app) {
        logger(for: category).info("\(message, privacy: .public)")
        appendToFile("INFO", category, message)
    }

    static func error(_ message: String, category: Category = .app) {
        logger(for: category).error("\(message, privacy: .public)")
        // Errors are worth persisting even with debug logging switched off.
        appendToFile("ERROR", category, message, force: true)
    }

    private static func appendToFile(
        _ level: String,
        _ category: Category,
        _ message: String,
        force: Bool = false
    ) {
        guard force || fileLoggingEnabled else { return }
        let line = "\(stamp.string(from: Date())) [\(level)] [\(category.rawValue)] \(message)\n"
        fileQueue.async {
            Paths.ensureDirectories()
            let url = Paths.logFile
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
