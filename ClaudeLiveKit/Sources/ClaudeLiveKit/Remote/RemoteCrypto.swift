import Foundation
import CryptoKit

/// End-to-end encryption between the Mac and the phone.
///
/// The relay is a stranger. It is a program on somebody else's computers, and
/// through it pass project names, the commands Claude wants to run, and — from
/// phase 7 — what Claude actually writes. Encrypting at the edges means the
/// relay forwards sealed boxes it cannot open, so trusting it is not required
/// and a breach of it discloses nothing.
///
/// `ChaChaPoly` rather than AES-GCM: both are authenticated and either would do,
/// but ChaCha20-Poly1305 needs no hardware acceleration to be fast, which keeps
/// the cost even across the range of devices this has to run on.
public enum RemoteCrypto {

    public enum Failure: Error, Equatable {
        case malformedKey
        case malformedPayload
        /// Decryption failed: the wrong key, or the bytes were altered in
        /// transit. Deliberately one case — telling the two apart would tell an
        /// attacker which half they got right.
        case couldNotOpen
    }

    // MARK: - La chiave

    /// A fresh 256-bit key. Generated on the Mac at pairing and carried to the
    /// phone by QR code, so it never travels through the relay.
    public static func newKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// The key as text, for the QR code and the Keychain.
    public static func export(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    public static func importKey(_ text: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: text), data.count == 32 else {
            throw Failure.malformedKey
        }
        return SymmetricKey(data: data)
    }

    // MARK: - Sigillare e aprire

    /// Encodes, seals, and returns something safe to put in a JSON field.
    public static func seal<T: Encodable>(_ value: T, with key: SymmetricKey) throws -> String {
        let plaintext = try Wire.encoder.encode(value)
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        // `combined` is nonce ‖ ciphertext ‖ tag: everything the other end needs,
        // so no part of it has to be carried separately and kept in step.
        return sealed.combined.base64EncodedString()
    }

    public static func open<T: Decodable>(
        _ type: T.Type,
        from base64: String,
        with key: SymmetricKey
    ) throws -> T {
        guard let combined = Data(base64Encoded: base64) else {
            throw Failure.malformedPayload
        }
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw Failure.malformedPayload
        }

        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: key)
        } catch {
            // Authentication failed. Nothing else may be attempted with these
            // bytes: unauthenticated plaintext is not plaintext, it is an
            // attacker's suggestion.
            throw Failure.couldNotOpen
        }

        do {
            return try Wire.decoder.decode(type, from: plaintext)
        } catch {
            throw Failure.malformedPayload
        }
    }
}
