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

    /// Lo script che questa build porta con sé.
    static func bundledHookURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "claude-hub-status", withExtension: "py") {
            return bundled
        }
        var directory = Bundle.main.bundleURL
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Resources/claude-hub-status.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static var installedHookURL: URL {
        Paths.home.appendingPathComponent(".claude-hub/bin/claude-hub-status.py")
    }

    /// Se la copia in uso non è quella di questa build.
    ///
    /// Confrontata per contenuto e non per data: un aggiornamento ripristina i
    /// file con le date che gli pare, e un numero di versione dentro lo script
    /// sarebbe una cosa in più da ricordarsi di alzare — cioè una cosa in più da
    /// dimenticare.
    static func installedHookIsStale() -> Bool {
        guard let bundled = bundledHookURL(),
              let shipped = try? Data(contentsOf: bundled),
              let installed = try? Data(contentsOf: installedHookURL)
        else {
            // Niente installato, o niente nel bundle: non c'è nulla di stantio.
            // Se gli hook *debbano* esserci è la domanda di `areHooksInstalled`,
            // e installare qualcosa che nessuno ha chiesto non è affare di questa
            // funzione.
            return false
        }
        return installed != shipped
    }

    /// Porta la copia installata alla versione di questa build.
    ///
    /// Gli hook sono una copia in `~/.claude-hub/bin`, quindi aggiornare l'app
    /// lascia in vita lo script vecchio: ogni correzione che vive lì dentro resta
    /// inerte finché qualcuno non premesse un bottone di cui non ha ragione di
    /// sapere. La 0.6.5 e la 0.7.0 sono uscite entrambe con una riga nelle note
    /// che lo chiedeva — il genere di istruzione che nessuno legge, e che nessuno
    /// dovrebbe dover leggere.
    ///
    /// Non installa mai ciò che non c'era già. Se gli hook non sono mai stati
    /// messi, un aggiornamento non è il momento di deciderlo per l'utente.
    @discardableResult
    static func refreshIfStale() -> Bool {
        guard areHooksInstalled(), installedHookIsStale() else { return false }
        switch run() {
        case .success:
            Log.info("Hook aggiornati alla versione di questa build.", category: .status)
            return true
        case .failure(let message):
            Log.error("Aggiornamento degli hook fallito: \(message)", category: .status)
            return false
        }
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
