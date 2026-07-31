import Foundation
import ServiceManagement

/// Registers the app to start at login, via `SMAppService`.
///
/// Requires a signed bundle in a stable location — `/Applications` in practice.
/// Registration from a build directory tends to fail, which is why the installer
/// puts the app in `/Applications` before this is offered.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS is waiting for the user to allow the item in
    /// System Settings → General → Login Items.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("Avvio al login: \(enabled ? "attivato" : "disattivato") (stato \(statusDescription))")
            return .success(())
        } catch {
            Log.error("Avvio al login non modificato: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "attivo"
        case .requiresApproval: return "in attesa di approvazione"
        case .notRegistered: return "non registrato"
        case .notFound: return "non trovato"
        @unknown default: return "sconosciuto"
        }
    }

    static func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

#if canImport(AppKit)
import AppKit
#endif
