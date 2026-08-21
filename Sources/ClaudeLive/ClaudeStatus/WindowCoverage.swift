import AppKit
import ApplicationServices
import CoreGraphics
import ClaudeLiveKit

/// Quali finestre di progetto sono coperte da altre finestre.
///
/// Serve a decidere se trattenere una richiesta di permesso anche quando l'utente
/// è al Mac. Il criterio **non** è «è la finestra attiva»: con due schermi una
/// finestra non attiva è perfettamente visibile, e trattenere lì significherebbe
/// togliere il prompt da sotto gli occhi di chi lo sta già guardando. Il criterio
/// è se quella finestra si possa **vedere**.
///
/// ## Come
///
/// L'elenco delle finestre a schermo arriva ordinato da davanti a dietro, con le
/// loro posizioni: basta a sapere chi copre chi. Non basta a sapere *quale
/// progetto* sia una finestra, perché i titoli sono protetti — quelli si leggono
/// con l'Accessibilità, che è il permesso che l'app già chiede per spegnere il
/// segnale sul progetto giusto. Senza quel permesso questa risposta non c'è, e il
/// comportamento resta quello di prima.
///
/// La copertura è misurata campionando una griglia di punti, non sottraendo
/// poligoni: la geometria esatta è precisione buttata per una domanda che è «si
/// legge o no», e una griglia dà la stessa risposta in venti righe.
///
/// Una finestra che esiste ma non è nell'elenco di quelle a schermo — ridotta a
/// icona, o su un'altra Scrivania — conta come coperta, ed è il caso più netto di
/// tutti: là il prompt non lo vedresti mai.
@MainActor
enum WindowCoverage {
    /// Sotto questa frazione di superficie visibile, la finestra è coperta.
    ///
    /// Un terzo e non «del tutto invisibile» perché una finestra di cui si vede
    /// una striscia non è una finestra che si sta leggendo.
    private static let visibleThreshold = 0.35

    private static let gridX = 9
    private static let gridY = 7

    /// I percorsi dei progetti la cui finestra non è visibile.
    static func coveredProjects(catalog: WorkspaceCatalog) -> Set<String> {
        guard AXIsProcessTrusted() else { return [] }

        let onScreen = orderedWindows()
        guard !onScreen.isEmpty else { return [] }

        // Un progetto è coperto solo se *nessuna* delle sue finestre è visibile.
        var visible: [String: Bool] = [:]
        /// La frazione migliore vista per ogni progetto, solo per il diario.
        var measured: [String: Double] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  EditorApp.all.contains(where: { $0.bundleID == bundleID })
            else { continue }

            for window in axWindows(pid: app.processIdentifier) {
                guard let project = VSCodeCLI.resolveProject(fromTitle: window.title, catalog: catalog).path
                else { continue }

                let seen = fraction(of: window.frame, pid: app.processIdentifier, in: onScreen)
                visible[project] = (visible[project] ?? false) || seen >= visibleThreshold
                measured[project] = max(measured[project] ?? 0, seen)
            }
        }

        // Il diario dice cosa si è visto, non solo la conclusione: «coperta o no»
        // è un giudizio su una misura, e senza la misura un giudizio sbagliato non
        // è diagnosticabile.
        if !measured.isEmpty {
            let summary = measured
                .sorted { $0.key < $1.key }
                .map { "\(($0.key as NSString).lastPathComponent) \(Int($0.value * 100))%" }
                .joined(separator: ", ")
            Log.debug("Visibilità finestre: \(summary)", category: .status)
        }

        return Set(visible.filter { !$0.value }.keys)
    }

    // MARK: - Le finestre a schermo, da davanti a dietro

    private struct Layered {
        let pid: pid_t
        let frame: CGRect
    }

    private static func orderedWindows() -> [Layered] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let mine = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { entry in
            // Solo il livello normale: pannelli, menu e alone di Claude Live vivono
            // sopra tutto e coprirebbero qualunque cosa senza nascondere niente.
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != mine,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 1, h > 1
            else { return nil }
            return Layered(pid: pid, frame: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    // MARK: - Le finestre di un editor, con titolo e posizione

    private struct EditorWindow {
        let title: String
        let frame: CGRect
    }

    private static func axWindows(pid: pid_t) -> [EditorWindow] {
        let app = AXUIElementCreateApplication(pid)
        // Come altrove: un editor occupato a indicizzare non deve poter bloccare
        // il thread principale per i sei secondi del timeout predefinito.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }

        return windows.compactMap { window in
            guard let title = attribute(window, kAXTitleAttribute) as? String, !title.isEmpty,
                  let positionValue = attribute(window, kAXPositionAttribute),
                  let sizeValue = attribute(window, kAXSizeAttribute)
            else { return nil }

            var origin = CGPoint.zero
            var size = CGSize.zero
            // swiftlint:disable:next force_cast — gli attributi AX sono AXValue.
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                  size.width > 1, size.height > 1
            else { return nil }

            return EditorWindow(title: title, frame: CGRect(origin: origin, size: size))
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    // MARK: - Quanto se ne vede

    /// La frazione di `frame` che nessuna finestra davanti copre.
    ///
    /// Restituisce 0 se la finestra non è fra quelle a schermo: ridotta a icona o
    /// su un'altra Scrivania, che è coperta nel modo più completo possibile.
    private static func fraction(of frame: CGRect, pid: pid_t, in ordered: [Layered]) -> Double {
        // La stessa finestra nell'elenco, riconosciuta da processo e posizione: i
        // titoli non ci sono, le coordinate sì, e coincidono con quelle di AX.
        guard let index = ordered.firstIndex(where: { entry in
            entry.pid == pid
                && abs(entry.frame.origin.x - frame.origin.x) < 3
                && abs(entry.frame.origin.y - frame.origin.y) < 3
                && abs(entry.frame.width - frame.width) < 3
                && abs(entry.frame.height - frame.height) < 3
        }) else { return 0 }

        let inFront = ordered[..<index].map(\.frame)
        guard !inFront.isEmpty else { return 1 }

        var seen = 0
        var total = 0
        for row in 0..<gridY {
            for column in 0..<gridX {
                // Punti al centro delle celle: sui bordi cadrebbero esattamente
                // sulle cuciture fra finestre affiancate, dove la risposta è
                // arbitraria.
                let point = CGPoint(
                    x: frame.minX + frame.width * (Double(column) + 0.5) / Double(gridX),
                    y: frame.minY + frame.height * (Double(row) + 0.5) / Double(gridY)
                )
                total += 1
                if !inFront.contains(where: { $0.contains(point) }) { seen += 1 }
            }
        }
        return total > 0 ? Double(seen) / Double(total) : 1
    }
}
