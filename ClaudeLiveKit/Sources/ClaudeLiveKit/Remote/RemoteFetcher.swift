import Foundation
import CryptoKit

/// Chiedere la fotografia al relay e aprirla. Nient'altro.
///
/// ## Perché è uscita da `RemoteStore`
///
/// Stava dentro `RemoteStore.refresh()`, che è un oggetto osservabile legato alla
/// vista: vive quando la vista vive. Da quando l'app può essere **svegliata in
/// sottofondo** da una notifica silenziosa, esiste un momento in cui bisogna
/// leggere la fotografia e quella vista non c'è — `AppDelegate.store` viene
/// assegnato in `RootView.onAppear`, e a un risveglio in sottofondo `onAppear`
/// non accade.
///
/// La scelta era fra due copie della stessa lettura e una funzione senza stato
/// che le due sponde chiamano. Due copie di un percorso di rete divergono, e la
/// divergenza qui si vedrebbe come «l'app aggiornata mostra una cosa, il widget
/// un'altra» — cioè come un guasto senza colpevole.
public enum RemoteFetcher {

    /// Cosa è andato storto, in una forma su cui si può decidere.
    ///
    /// Distinta da `RemoteCrypto.Failure` di proposito: là si sa solo che una
    /// scatola non si è aperta, qui si sa se il problema è la rete, il relay, o
    /// il fatto che questi due dispositivi hanno chiavi diverse — che sono tre
    /// cure diverse. Chi chiama traduce in una frase; questo tipo non contiene
    /// frasi perché le due sponde le dicono in posti diversi.
    public enum Failure: Error, Equatable {
        /// Il relay c'è ma il Mac non ha ancora pubblicato niente (404).
        case nothingPublished
        /// Il relay ha rifiutato la parola d'ordine (401).
        case refused
        case http(Int)
        /// Il relay ha risposto qualcosa che non è una fotografia.
        case unreadableResponse
        /// La scatola non si apre: questo telefono e quel Mac hanno chiavi
        /// diverse. Nessuna quantità di tentativi lo risolve.
        case wrongKey
        /// La scatola è illeggibile per un motivo che non è la chiave.
        case malformed
        case unreachable
    }

    /// L'ultima fotografia che il Mac ha pubblicato.
    public static func snapshot(
        relayURL: String,
        pairID: String,
        key: SymmetricKey,
        session: URLSession = .shared
    ) async throws -> RemoteSnapshot {
        guard let url = URL(string: relayURL + "/state") else { throw Failure.unreachable }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 15
        // Sempre dalla rete: uno stato servito da una cache in silenzio è l'unico
        // guasto che questa app non può permettersi.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }

        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 404: throw Failure.nothingPublished
        case 401: throw Failure.refused
        case let code: throw Failure.http(code)
        }

        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = body["payload"] as? String
        else { throw Failure.unreadableResponse }

        do {
            return try RemoteCrypto.open(RemoteSnapshot.self, from: payload, with: key)
        } catch RemoteCrypto.Failure.couldNotOpen {
            throw Failure.wrongKey
        } catch {
            throw Failure.malformed
        }
    }
}
