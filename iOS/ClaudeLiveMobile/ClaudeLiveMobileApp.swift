import SwiftUI
import UIKit
import ClaudeLiveKit

/// Remote notifications still arrive through the app delegate: SwiftUI has no
/// equivalent hook for the APNs token, so this is the one piece of UIKit the
/// app needs.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by the app before registration is requested.
    static weak var probe: RelayProbe?
    static weak var store: RemoteStore?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Handed to both: the store is what the Mac's alerts reach, the probe is
        // the phase 0 stopwatch. Whichever asked for registration, the token is
        // the same and both need it.
        Task { @MainActor in
            AppDelegate.probe?.didRegister(tokenData: deviceToken)
            await AppDelegate.store?.registerDevice(token: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in AppDelegate.probe?.didFailToRegister(error: error) }
    }

    /// La notifica silenziosa che tiene vivi i widget ad app chiusa.
    ///
    /// ## Perché passa da qui e non dal widget
    ///
    /// La fotografia del Mac è cifrata, e la chiave sta nel portachiavi. Da
    /// un'estensione il portachiavi **non risponde** — `-25291`, misurato — per
    /// cui un widget non può decifrare niente da sé: nessuno gli consegna una
    /// chiave come il sistema fa con la Live Activity. Chi può aprire quella
    /// scatola è soltanto l'app.
    ///
    /// Quindi il relay non manda il contenuto: manda un **colpetto**. L'app si
    /// sveglia, va a prendere la fotografia, la apre, deposita il risultato in
    /// chiaro nel contenitore condiviso e ricarica i widget. Il contenuto non
    /// passa mai in chiaro per Apple né per il relay, che è la proprietà su cui
    /// tutto questo sistema è costruito.
    ///
    /// ## Perché non usa lo store
    ///
    /// `AppDelegate.store` lo assegna `RootView.onAppear`. A un risveglio in
    /// sottofondo quella vista **non esiste**, quindi qui sarebbe `nil` e la
    /// notifica non farebbe niente — in silenzio, che è il modo peggiore.
    /// `RemoteFetcher` e `RemoteStore.handToWidgets` sono senza stato proprio per
    /// poter essere chiamati da qui.
    ///
    /// ## Perché non il push per widget di Apple
    ///
    /// Esiste, ed è fatto esattamente per questo: `apns-push-type: widgets`, con
    /// un bilancio suo separato da quello dei risvegli in sottofondo, e un
    /// `WidgetPushHandler` che riceve il token. È di **iOS 26**, presentato alla
    /// WWDC25 — e questa app dichiara come minimo iOS 18.
    ///
    /// Le due strade per averlo erano alzare il minimo, cioè lasciare indietro
    /// chiunque provi l'app da un telefono più vecchio, o dichiarare i widget in
    /// due varianti dietro un `@available` e tenere in pari due percorsi
    /// d'aggiornamento. Nessuna delle due vale l'unica cosa che si guadagna: un
    /// bilancio separato. La notifica silenziosa funziona dov'è già installata,
    /// riusa il token che il relay ha, e non tocca le autorizzazioni
    /// dell'estensione.
    ///
    /// Se un giorno il minimo salisse a iOS 26 per altri motivi, questo è il
    /// posto da cui guardare: il relay ha già la forma giusta — `PUSH_SHAPE` in
    /// `relay/src/index.ts` prende un tipo in più con una riga.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            completionHandler(await AppDelegate.refreshForWidgets())
        }
    }

    /// Legge la fotografia e la deposita per i widget.
    ///
    /// La risposta a iOS è quella vera e non sempre `.newData`: il sistema impara
    /// da qui quanto valga svegliare quest'app, e chi risponde «dati nuovi» a
    /// ogni colpetto si fa strozzare il canale — perdendo anche i risvegli che
    /// servivano.
    @MainActor
    static func refreshForWidgets() async -> UIBackgroundFetchResult {
        let relay = RemoteStore.storedRelayURL
        guard !relay.isEmpty,
              let pairID = RemoteSecrets.read(.pairID),
              let keyText = RemoteSecrets.read(.encryptionKey),
              let key = try? RemoteCrypto.importKey(keyText)
        else {
            // Non accoppiato, o portachiavi al buio perché il telefono è stato
            // riavviato e non ancora sbloccato. Non è un guasto: non c'è niente
            // da leggere e non c'era niente da leggere.
            return .noData
        }

        do {
            let snapshot = try await RemoteFetcher.snapshot(
                relayURL: relay,
                pairID: pairID,
                key: key
            )
            return RemoteStore.handToWidgets(snapshot) ? .newData : .noData
        } catch {
            return .failed
        }
    }
}

@main
struct ClaudeLiveMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var probe = RelayProbe()

    var body: some Scene {
        WindowGroup {
            RootView(probe: probe)
                .onAppear { AppDelegate.probe = probe }
        }
    }
}
