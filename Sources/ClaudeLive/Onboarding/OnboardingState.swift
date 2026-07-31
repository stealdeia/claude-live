import AppKit
import Combine
import UserNotifications

/// Result of a single requirement check.
enum CheckState: Equatable {
    case unknown
    case checking
    case ok(String)
    case warning(String)
    case failed(String)

    var isSatisfied: Bool {
        if case .ok = self { return true }
        return false
    }

    var symbol: String {
        switch self {
        case .unknown: return "circle.dashed"
        case .checking: return "ellipsis.circle"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var message: String {
        switch self {
        case .unknown: return "da verificare"
        case .checking: return "verifica in corso…"
        case .ok(let text), .warning(let text), .failed(let text): return text
        }
    }
}

/// Runs the first-run checks and exposes them to the wizard.
///
/// Every check is something that has bitten during development, so each one
/// reports a concrete next step rather than a bare pass/fail.
@MainActor
final class OnboardingState: ObservableObject {
    @Published var claudeCode: CheckState = .unknown
    @Published var keychain: CheckState = .unknown
    @Published var hooks: CheckState = .unknown
    @Published var notifications: CheckState = .unknown
    @Published var vsCode: CheckState = .unknown
    @Published var loginItem: CheckState = .unknown

    /// True when the app is running from /Applications, which login-item
    /// registration effectively requires.
    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    func checkAll() {
        checkClaudeCode()
        checkKeychain()
        checkHooks()
        checkNotifications()
        checkVSCode()
        checkLoginItem()
    }

    // MARK: - Individual checks

    func checkClaudeCode() {
        let claudeDir = Paths.home.appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            claudeCode = .failed("~/.claude non esiste: Claude Code non è installato")
            return
        }
        claudeCode = .ok("Claude Code presente")
    }

    /// The important one: reading the credentials is what triggers the macOS
    /// keychain dialog, and clicking "Allow" instead of "Always Allow" makes it
    /// reappear on every check.
    func checkKeychain() {
        keychain = .checking
        Task {
            let result: Result<ClaudeCredentials, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try CredentialsStore.load()) }
                catch { return .failure(error) }
            }.value

            switch result {
            case .success(let credentials):
                let plan = credentials.subscriptionType ?? "?"
                if credentials.isExpired {
                    keychain = .warning("Token scaduto: esegui un comando `claude` per rinnovarlo")
                } else {
                    keychain = .ok("Accesso riuscito (piano \(plan))")
                }
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                keychain = .failed(message)
            }
        }
    }

    func checkHooks() {
        hooks = HookInstaller.areHooksInstalled()
            ? .ok("Hook installati")
            : .warning("Non installati: lo stato per progetto non sarà disponibile")
    }

    func checkNotifications() {
        notifications = .checking
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.notifications = .ok("Autorizzate")
                case .denied:
                    self.notifications = .warning("Negate: attivale in Impostazioni di Sistema → Notifiche")
                case .notDetermined:
                    self.notifications = .warning("Non ancora richieste")
                @unknown default:
                    self.notifications = .unknown
                }
            }
        }
    }

    func checkVSCode() {
        let installed = EditorApp.all.contains { editor in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) != nil
        }
        vsCode = installed
            ? .ok("Visual Studio Code trovato")
            : .warning("Non installato: la lista progetti resterà vuota")
    }

    func checkLoginItem() {
        if LoginItem.isEnabled {
            loginItem = .ok("Attivo")
        } else if LoginItem.requiresApproval {
            loginItem = .warning("Da approvare in Impostazioni di Sistema → Elementi login")
        } else if !isInstalledInApplications {
            loginItem = .warning("Sposta l'app in Applicazioni per poterlo attivare")
        } else {
            loginItem = .warning("Non attivo")
        }
    }

    // MARK: - Actions

    func requestNotifications() {
        notifications = .checking
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.checkNotifications() }
        }
    }

    func enableLoginItem() {
        _ = LoginItem.setEnabled(true)
        checkLoginItem()
    }
}
