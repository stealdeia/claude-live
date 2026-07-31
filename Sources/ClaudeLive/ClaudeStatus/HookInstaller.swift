import Foundation

/// Detects and runs the hook installer that ships inside the app bundle.
///
/// The installer itself is a Python script (`install-claude-hooks.py`) so it can
/// be run by hand from a terminal too — the app just shells out to the same
/// script rather than duplicating the settings.json merge logic in Swift.
enum HookInstaller {
    /// The string that identifies our entries in settings.json.
    private static let marker = "claude-hub-status.py"

    private static var claudeSettingsURL: URL {
        Paths.home.appendingPathComponent(".claude/settings.json")
    }

    /// Path to the installer, both inside the built .app and when running the
    /// bare executable out of .build during development.
    static func installerScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "install-claude-hooks", withExtension: "py") {
            return bundled
        }
        // Development fallback: walk up from the executable to the repo's Resources.
        var directory = Bundle.main.bundleURL
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Resources/install-claude-hooks.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// True when at least one of our hook entries is present in settings.json.
    static func areHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return false }

        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                for entry in entries {
                    if let command = entry["command"] as? String, command.contains(marker) {
                        return true
                    }
                }
            }
        }
        return false
    }

    enum InstallResult {
        case success(log: String)
        case failure(message: String)
    }

    /// Runs the installer. `uninstall` removes only our own entries.
    static func run(uninstall: Bool = false) -> InstallResult {
        guard let script = installerScriptURL() else {
            return .failure(message: "Script install-claude-hooks.py non trovato nel bundle.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["python3", script.path]
        if uninstall { arguments.append("--uninstall") }
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return .failure(message: "Avvio dell'installer fallito: \(error.localizedDescription)")
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        Log.info("Installer hook (uninstall=\(uninstall)) exit \(process.terminationStatus):\n\(output)", category: .status)

        guard process.terminationStatus == 0 else {
            return .failure(message: output.isEmpty
                ? "Installer terminato con codice \(process.terminationStatus)."
                : output)
        }
        return .success(log: output)
    }
}
