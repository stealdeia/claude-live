import Foundation
import SwiftUI

/// Quali avvisi questo telefono vuole ricevere.
///
/// Le tre categorie sono le stesse che l'app per Mac lascia scegliere, perché
/// sono i tre motivi per cui il Mac chiama il relay. Quello che *non* sono è le
/// notifiche di soglia d'uso: quelle il Mac le mostra a sé e non le spinge.
///
/// ## Dove vive la decisione
///
/// Sul relay, non sul Mac. Il Mac interroga il relay solo mentre c'è qualcosa da
/// rispondere: una preferenza cambiata a metà pomeriggio gli resterebbe non
/// letta per ore, e nel frattempo le notifiche continuerebbero ad arrivare. Il
/// relay invece decide se spingere a ogni pubblicazione.
///
/// Sul telefono resta la copia locale, che è la verità per l'interfaccia: gli
/// interruttori devono rispondere subito anche senza rete, e la rete si allinea
/// dopo. Se la chiamata fallisce, la prossima apertura dell'app la rifà.
@MainActor
final class NotificationPreferences: ObservableObject {
    /// Quando Claude aspetta una risposta — un permesso o una domanda.
    @Published var waiting: Bool { didSet { save(); publish() } }

    /// Quando Claude ha finito.
    @Published var done: Bool { didSet { save(); publish() } }

    /// Quando Claude si è interrotto.
    @Published var failed: Bool { didSet { save(); publish() } }

    /// Come è andata l'ultima volta che si è provato a dirlo al relay. Mostrato
    /// solo quando è andata male: un'interfaccia che conferma ogni successo
    /// insegna a ignorare i suoi messaggi.
    @Published private(set) var problem: String?

    private let defaults = UserDefaults.standard
    private var store: RemoteStore?

    private enum Key {
        static let waiting = "notify.waiting"
        static let done = "notify.done"
        static let failed = "notify.failed"
    }

    init() {
        // Accese quando non se n'è mai parlato: chi installa l'app la installa
        // per essere avvisato, e un silenzio predefinito sembrerebbe un guasto.
        waiting = defaults.object(forKey: Key.waiting) as? Bool ?? true
        done = defaults.object(forKey: Key.done) as? Bool ?? true
        failed = defaults.object(forKey: Key.failed) as? Bool ?? true
    }

    /// Collega il canale verso il relay e allinea subito ciò che il relay sa.
    ///
    /// Rifatto a ogni avvio come la registrazione del token, e per lo stesso
    /// motivo: una chiamata può essere fallita mentre il telefono era senza rete,
    /// e uno stato disallineato qui non si vede — si vede solo come una notifica
    /// che arriva quando l'interruttore dice che non dovrebbe.
    func attach(to store: RemoteStore) {
        self.store = store
        publish()
    }

    private func save() {
        defaults.set(waiting, forKey: Key.waiting)
        defaults.set(done, forKey: Key.done)
        defaults.set(failed, forKey: Key.failed)
    }

    private func publish() {
        guard let store else { return }
        let payload = ["waiting": waiting, "done": done, "failed": failed]
        Task { [weak self] in
            let error = await store.sendNotificationPreferences(payload)
            await MainActor.run { self?.problem = error }
        }
    }
}
