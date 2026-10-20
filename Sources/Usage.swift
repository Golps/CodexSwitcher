import Foundation

/// How much of its Codex limits an account has used, as Codex's own /status
/// shows it: a short window (usually 5 hours) and a weekly one.
struct Usage: Equatable {
    struct Window: Equatable {
        let percent: Double          // 0–100
        let seconds: Int             // length of the window
        let resetsAt: Date

        /// Once the reset time has passed the limit is back to zero, even
        /// before the next check comes back.
        func percent(at now: Date) -> Double { now >= resetsAt ? 0 : percent }

        var name: String {
            switch seconds {
            case 0: return "Limit"
            case 604_800: return "Weekly"
            case let s where s % 86_400 == 0: return "\(s / 86_400)-day"
            default: return "\(Int((Double(seconds) / 3600).rounded()))-hour"
            }
        }
    }

    let windows: [Window]
    let limitReached: Bool
}

enum UsageState: Equatable {
    case loading
    case loaded(Usage)
    case unavailable(String)
}

/// Reads usage from the same ChatGPT endpoint Codex uses.
enum UsageClient {
    private static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// No cache at all, so the menu never shows a stored copy of old numbers.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    /// Fetches usage for the login in `auth` (an auth.json). When the access
    /// token has expired and `mayRefresh` is set, it refreshes the login first
    /// and returns the new auth.json alongside the usage, for the caller to save.
    static func fetch(auth: Data, mayRefresh: Bool) async throws -> (Usage, Data?) {
        let tokens = try tokensOf(auth)
        let (status, body) = try await request(tokens)
        if status == 401 && mayRefresh {
            let fresh = try await refresh(auth)
            let (status, body) = try await request(try tokensOf(fresh))
            return (try parse(status, body), fresh)
        }
        if status == 401 { throw UsageError.needsCodex }
        return (try parse(status, body), nil)
    }

    private static func tokensOf(_ auth: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: auth) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              tokens["access_token"] is String else { throw UsageError.signedOut }
        return tokens
    }

    private static func request(_ tokens: [String: Any]) async throws -> (Int, Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(tokens["access_token"] as? String ?? "")", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func parse(_ status: Int, _ body: Data) throws -> Usage {
        if status == 401 || status == 403 { throw UsageError.signedOut }
        guard status == 200, let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw UsageError.unavailable }
        let limits = root["rate_limit"] as? [String: Any]
        let windows = ["primary_window", "secondary_window"].compactMap { key -> Usage.Window? in
            guard let w = limits?[key] as? [String: Any] else { return nil }
            let percent = (w["used_percent"] as? NSNumber)?.doubleValue ?? 0
            let seconds = (w["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
            let resetsAt: Date
            if let at = (w["reset_at"] as? NSNumber)?.doubleValue, at > 0 {
                resetsAt = Date(timeIntervalSince1970: at)
            } else {
                resetsAt = Date().addingTimeInterval((w["reset_after_seconds"] as? NSNumber)?.doubleValue ?? 0)
            }
            return Usage.Window(percent: min(max(percent, 0), 100), seconds: seconds, resetsAt: resetsAt)
        }
        return Usage(windows: windows, limitReached: limits?["limit_reached"] as? Bool ?? false)
    }

    /// Same refresh Codex does: trade the refresh token for new tokens.
    private static func refresh(_ auth: Data) async throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: auth) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String else { throw UsageError.signedOut }
        var request = URLRequest(url: URL(string: "\(WebSignIn.issuer)/oauth/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": WebSignIn.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = fresh["access_token"] as? String
        else { throw UsageError.signedOut }
        tokens["access_token"] = access
        if let id = fresh["id_token"] as? String { tokens["id_token"] = id }
        if let refresh = fresh["refresh_token"] as? String { tokens["refresh_token"] = refresh }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

enum UsageError: LocalizedError {
    case signedOut
    case needsCodex
    case unavailable

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign-in expired. Remove and add this account again."
        case .needsCodex: return "Open Codex to refresh this account's usage."
        case .unavailable: return "Usage unavailable right now."
        }
    }
}
