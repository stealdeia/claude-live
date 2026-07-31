import Foundation

/// Result of one usage probe. A 429 is a *success* here: the response still
/// carries the rate-limit headers, which is all we actually wanted.
struct UsageProbeResult {
    let snapshot: UsageSnapshot
    /// Every `anthropic-ratelimit-*` header verbatim, for the debug pane.
    let rawHeaders: [String: String]
}

enum UsageProbeError: Error {
    case unauthorized          // 401/403 — token no longer accepted
    case http(Int, String?)
    case transport(Error)
    case noRateLimitHeaders([String: String])
}

/// Sends the smallest possible `/v1/messages` request purely to read the
/// rate-limit headers off the response.
///
/// Three details are non-obvious and all three are required for a Claude Code
/// OAuth token to be accepted (verified empirically):
///   1. `Authorization: Bearer <oauth token>` — *not* `x-api-key`.
///   2. `anthropic-beta: oauth-2025-04-20`.
///   3. The Claude Code system prompt as the first system block.
/// Drop any one of them and the API answers 401.
struct UsageAPIClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Cheapest model available; with max_tokens=1 the cost is negligible.
    static let probeModel = "claude-haiku-4-5-20251001"

    private static let claudeCodeSystemPrompt =
        "You are Claude Code, Anthropic's official CLI for Claude."

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [:]
        session = URLSession(configuration: config)
    }

    func probe(credentials: ClaudeCredentials, logHeaders: Bool) async throws -> UsageProbeResult {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("claude-cli/2.0.0 (external, cli)", forHTTPHeaderField: "user-agent")

        let body: [String: Any] = [
            "model": Self.probeModel,
            "max_tokens": 1,
            "system": [["type": "text", "text": Self.claudeCodeSystemPrompt]],
            "messages": [["role": "user", "content": "."]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageProbeError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageProbeError.http(-1, "risposta non HTTP")
        }

        let headers = normalizedHeaders(from: http)

        if logHeaders {
            let rateLimitOnly = headers
                .filter { $0.key.hasPrefix("anthropic-ratelimit") }
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n  ")
            Log.debug("HTTP \(http.statusCode) — header rate limit:\n  \(rateLimitOnly)", category: .usage)
        }

        // 429 carries the headers we want, so it is a valid reading, not a failure.
        switch http.statusCode {
        case 200...299, 429:
            break
        case 401, 403:
            throw UsageProbeError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8)?.prefix(300).description
            throw UsageProbeError.http(http.statusCode, message)
        }

        guard let snapshot = Self.parseSnapshot(
            headers: headers,
            httpStatus: http.statusCode,
            subscriptionType: credentials.subscriptionType
        ) else {
            throw UsageProbeError.noRateLimitHeaders(headers)
        }

        return UsageProbeResult(
            snapshot: snapshot,
            rawHeaders: headers.filter { $0.key.hasPrefix("anthropic-") }
        )
    }

    private func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            result[key.lowercased()] = value
        }
        return result
    }

    // MARK: - Header parsing

    /// Header names verified against a live response:
    /// ```
    /// anthropic-ratelimit-unified-5h-utilization: 0.17
    /// anthropic-ratelimit-unified-5h-reset: 1785498000
    /// anthropic-ratelimit-unified-5h-status: allowed
    /// anthropic-ratelimit-unified-7d-utilization: 0.18
    /// anthropic-ratelimit-unified-7d-reset: 1785740400
    /// anthropic-ratelimit-unified-representative-claim: five_hour
    /// ```
    static func parseSnapshot(
        headers: [String: String],
        httpStatus: Int,
        subscriptionType: String?
    ) -> UsageSnapshot? {
        let fiveHour = window(prefix: "anthropic-ratelimit-unified-5h", in: headers)
        let sevenDay = window(prefix: "anthropic-ratelimit-unified-7d", in: headers)
        // Not present on every plan; harmless when absent.
        let opus = window(prefix: "anthropic-ratelimit-unified-7d-opus", in: headers)
            ?? window(prefix: "anthropic-ratelimit-unified-opus-7d", in: headers)

        // If neither of the two main windows came back, the response told us
        // nothing useful — surface that rather than showing empty bars.
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return UsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            opusSevenDay: opus,
            representativeClaim: headers["anthropic-ratelimit-unified-representative-claim"],
            overallStatus: headers["anthropic-ratelimit-unified-status"],
            fetchedAt: Date(),
            httpStatus: httpStatus,
            subscriptionType: subscriptionType
        )
    }

    private static func window(prefix: String, in headers: [String: String]) -> UsageWindow? {
        guard let utilizationRaw = headers["\(prefix)-utilization"],
              let utilization = Double(utilizationRaw) else { return nil }

        let resetAt = headers["\(prefix)-reset"]
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }

        return UsageWindow(
            // The header is a 0…1 fraction; clamp defensively in case a future
            // API version starts sending 0…100.
            utilization: utilization > 1.0 ? (utilization / 100).clamped(to: 0...1)
                                           : utilization.clamped(to: 0...1),
            resetAt: resetAt,
            status: headers["\(prefix)-status"]
        )
    }
}
