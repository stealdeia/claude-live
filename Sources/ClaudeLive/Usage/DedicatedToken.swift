import AppKit
import Foundation
import Security

/// A long-lived token made for this app alone with `claude setup-token`.
///
/// ## Why it exists
///
/// The keychain item of Claude Code is renewed only by the Claude Code that runs
/// in a terminal or in VS Code. The Code tab of the Claude desktop app does not
/// touch it: it hands its own token to its own Claude Code and renews it itself.
/// Observed on 2026-10-15: with the work moved to the desktop app, the keychain
/// token had died on the 13th at 18:52 and the panel waited two days for a renewal
/// nobody was going to make.
///
/// `claude setup-token` is Anthropic's own way of giving a tool a token of its
/// own: valid for a year, with no refresh token, so there is nothing to rotate and
/// nothing to fight Claude Code over. The read-only rule in `CredentialsStore`
/// still holds — this is a separate token, not a renewal of theirs.
///
/// ## Where it lives
///
/// Our own keychain item, written by this app, so macOS never asks before reading
/// it. Not `settings.json`: that is a plain file anyone can read.
enum DedicatedToken {
    private static let service = "it.aldeialab.ClaudeLive.usage"
    private static let account = "setupToken"

    /// What `claude setup-token` prints. Checked so a stray paste — the command
    /// itself, half a line, the wrong token — is refused on the spot instead of
    /// showing up later as a 401.
    static let expectedPrefix = "sk-ant-oat"

    /// The token as pasted, cleaned of what copying from a terminal adds: spaces,
    /// line breaks, and the line wrap that splits a long token in two.
    static func normalized(_ pasted: String) -> String? {
        let token = pasted.components(separatedBy: .whitespacesAndNewlines).joined()
        guard token.hasPrefix(expectedPrefix), token.count > expectedPrefix.count + 20 else { return nil }
        return token
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Delete then add, as `RemoteSecrets` does: an update on a missing item fails,
    /// and a fresh item does not inherit attributes from whatever was there.
    @discardableResult
    static func write(_ token: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrLabel as String] = "Vibing Code Live — token per l'utilizzo"
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil)
    }

    /// Opens Terminal running `claude setup-token`. Returns an error message for
    /// the user, or nil.
    ///
    /// A `.command` file rather than AppleScript: telling Terminal what to do would
    /// need the Automation permission and its own dialog, while opening a file is
    /// something any app may do.
    ///
    /// The script looks for `claude` itself instead of trusting the PATH: the
    /// installer puts it in `~/.local/bin` and adds that to `.zshrc`, which a
    /// script does not read — observed on 2026-10-15, a terminal that answered
    /// «command not found» on a Mac where Claude Code works fine.
    static func openSetupInTerminal() -> String? {
        let script = """
        #!/bin/zsh
        clear
        for candidate in "$(command -v claude)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
          if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            echo "Accedi nel browser che si apre. Alla fine copia il token che compare qui"
            echo "(inizia con \(expectedPrefix)) e incollalo nelle Impostazioni di Vibing Code Live."
            echo
            "$candidate" setup-token
            exit
          fi
        done
        echo "Non trovo Claude Code su questo Mac."
        echo "Installalo da https://claude.com/claude-code e poi riprova da Vibing Code Live."
        """

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibing-code-live-token.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            Log.error("Script per il token non scritto: \(error.localizedDescription)", category: .keychain)
            return "Non riesco a preparare il Terminale: \(error.localizedDescription)"
        }

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return "Non trovo l'app Terminale."
        }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        Log.info("Terminale aperto per «claude setup-token»", category: .keychain)
        return nil
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
