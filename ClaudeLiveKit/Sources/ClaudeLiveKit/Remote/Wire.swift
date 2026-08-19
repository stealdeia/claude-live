import Foundation

/// One JSON dialect for both ends.
///
/// The `Codable` conformances of the domain types live beside the types
/// themselves: Swift only synthesises `init(from:)` in the file that declares
/// the type, so they cannot be gathered here even though that is where they
/// conceptually belong.
///
/// The date strategy is pinned rather than left to the default: `deferredToDate`
/// writes seconds since 2001, a choice that is invisible until something else
/// reads the payload and is quietly wrong by three decades. Epoch seconds is
/// also what the hook already writes in `~/.claude-hub/status/`, so the whole
/// system speaks one convention.
public enum Wire {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
