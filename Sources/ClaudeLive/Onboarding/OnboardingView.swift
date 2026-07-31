import SwiftUI
import AppKit

/// First-run wizard: walks through every requirement and permission in order.
///
/// Exists because the setup is genuinely multi-step — keychain access, Claude Code
/// hooks, notifications — and each step has a failure mode that is invisible
/// unless it is checked and explained.
struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    @ObservedObject var settings: Settings

    let onInstallHooks: () -> Void
    let onFinish: () -> Void

    @State private var step = 0

    private let steps = ["Benvenuto", "Requisiti", "Keychain", "Hook", "Notifiche", "Pronto"]

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0: welcome
                    case 1: requirements
                    case 2: keychainStep
                    case 3: hooksStep
                    case 4: notificationsStep
                    default: finish
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            navigation
        }
        .frame(width: 560, height: 470)
        .onAppear { state.checkAll() }
    }

    // MARK: - Chrome

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 4) {
                    Circle()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(index == step ? .primary : .secondary)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                        .frame(maxWidth: 14)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var navigation: some View {
        HStack {
            if step > 0 {
                Button("Indietro") { step -= 1 }
            }
            Spacer()
            Button("Salta configurazione") { onFinish() }
                .buttonStyle(.borderless)
            if step < steps.count - 1 {
                Button("Avanti") {
                    step += 1
                    state.checkAll()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Inizia a usare Claude Live") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Live")
                .font(.largeTitle.bold())
            Text("Versione \(UpdateController.currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Un pannello sempre visibile con:")
                .padding(.top, 6)

            bullet("gauge.with.needle", "I limiti del tuo account Claude", "Sessione 5 ore e settimana 7 giorni, con countdown al reset.")
            bullet("folder", "I progetti VS Code aperti", "Un clic porta in primo piano il progetto che vuoi.")
            bullet("dot.radiowaves.left.and.right", "Lo stato di Claude Code per progetto", "Sai se sta lavorando, se ha finito o se aspetta una tua risposta.")

            Text("La configurazione richiede un minuto. Nessun dato lascia il tuo Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Requisiti", "Claude Live legge dati che già esistono sul tuo Mac.")

            checkRow("Claude Code", state.claudeCode)
            Text("Serve Claude Code installato e con il login effettuato. Se manca: installalo, apri il Terminale ed esegui `claude`, poi accedi.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            checkRow("Visual Studio Code", state.vsCode)
            Text("Opzionale. Senza VS Code funzionano le barre di utilizzo, ma la lista progetti resta vuota.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Ricontrolla") { state.checkAll() }
                .padding(.top, 4)
        }
    }

    private var keychainStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Accesso al Keychain", "È il passaggio più importante.")

            Text("Claude Live legge il token del tuo account dalla voce di Keychain creata da Claude Code. Lo legge in sola lettura e non lo invia da nessuna parte: serve solo per chiedere all'API i tuoi livelli di utilizzo.")

            calloutBox(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Scegli «Consenti sempre», non «Consenti»",
                text: "macOS mostrerà una richiesta di accesso. Se scegli «Consenti» la richiesta tornerà a ogni controllo, ogni pochi minuti."
            )

            checkRow("Stato", state.keychain)

            Button("Verifica accesso ora") { state.checkKeychain() }
        }
    }

    private var hooksStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Hook di Claude Code", "Servono per lo stato per progetto.")

            Text("Gli hook sono piccoli comandi che Claude Code esegue quando inizia a lavorare, quando finisce o quando ti chiede un permesso. Scrivono un file di stato in ~/.claude-hub/status/ che Claude Live legge in tempo reale.")

            calloutBox(
                icon: "checkmark.shield",
                tint: .secondary,
                title: "Modifica sicura",
                text: "Il tuo ~/.claude/settings.json viene salvato in backup prima della modifica, e gli hook che hai già non vengono toccati. L'operazione è ripetibile senza accumulare duplicati."
            )

            checkRow("Stato", state.hooks)

            HStack {
                Button("Installa hook…") { onInstallHooks() }
                Button("Ricontrolla") { state.checkHooks() }
            }

            Text("Senza hook tutto il resto funziona: i progetti restano elencati, ma senza il pallino di stato.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var notificationsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Notifiche e avvio automatico", "Entrambi opzionali.")

            checkRow("Notifiche", state.notifications)
            Text("Claude Live avvisa quando Claude aspetta una tua risposta in un progetto, e quando ti avvicini ai limiti di utilizzo.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Richiedi autorizzazione") { state.requestNotifications() }

            Divider().padding(.vertical, 6)

            checkRow("Avvio al login", state.loginItem)
            if state.isInstalledInApplications {
                HStack {
                    Button("Attiva avvio al login") { state.enableLoginItem() }
                    if LoginItem.requiresApproval {
                        Button("Apri Impostazioni") { LoginItem.openLoginItemsSettings() }
                    }
                }
            } else {
                Text("L'app non è in /Applications: spostala lì per poter attivare l'avvio automatico.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Tutto pronto", "Claude Live vive nella barra dei menu.")

            bullet("menubar.arrow.up.rectangle", "Icona ✦ nella barra dei menu", "Mostra la percentuale della sessione 5h. Un pallino arancione compare quando Claude aspetta una risposta.")
            bullet("rectangle.on.rectangle", "Due modalità", "Pannello flottante trascinabile, oppure agganciato al notch se il tuo Mac ne ha uno. Si cambia dal menu.")
            bullet("arrow.triangle.2.circlepath", "Aggiornamenti automatici", "Claude Live controlla da sola se c'è una versione nuova e ti propone di installarla.")

            if !state.keychain.isSatisfied {
                calloutBox(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Accesso al Keychain non confermato",
                    text: "Le barre di utilizzo resteranno vuote. Puoi riaprire questa procedura dal menu della barra: «Configurazione guidata…»."
                )
            }

            Text("Puoi rivedere tutto in Impostazioni, e riaprire questa procedura dal menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pieces

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.title2.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checkRow(_ label: String, _ check: CheckState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: check.symbol)
                .foregroundStyle(color(for: check))
            Text(label).font(.callout.weight(.medium))
            Text(check.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func color(for check: CheckState) -> Color {
        switch check {
        case .ok: return PanelTheme.color(for: .normal)
        case .warning: return PanelTheme.color(for: .warning)
        case .failed: return PanelTheme.color(for: .danger)
        case .checking, .unknown: return .secondary
        }
    }

    private func calloutBox(icon: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
