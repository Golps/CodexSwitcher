import CryptoKit
import Foundation

/// Who a Codex `auth.json` belongs to, read from its ChatGPT ID token.
struct AuthIdentity {
    /// Stable id for the login: a hash of the workspace id and the user id.
    let key: String
    let email: String
    let plan: String
}

enum AuthFileError: LocalizedError {
    case notChatGPT
    case missingTokens
    case badIDToken

    var errorDescription: String? {
        switch self {
        case .notChatGPT: return "This Codex login isn't a ChatGPT sign-in (it may be an API key)."
        case .missingTokens: return "This Codex login is missing its ChatGPT tokens. Sign in again."
        case .badIDToken: return "This Codex login has an unreadable ID token. Sign in again."
        }
    }
}

enum AuthFile {
    static func identity(of data: Data) throws -> AuthIdentity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthFileError.missingTokens
        }
        if let mode = root["auth_mode"] as? String, mode.lowercased() != "chatgpt" {
            throw AuthFileError.notChatGPT
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              let idToken = tokens["id_token"] as? String,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty
        else { throw AuthFileError.missingTokens }

        let claims = try decodeJWTPayload(idToken)
        guard let subject = claims["sub"] as? String, !subject.isEmpty else { throw AuthFileError.badIDToken }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]

        let digest = SHA256.hash(data: Data((accountID + "\n" + subject).utf8))
        return AuthIdentity(
            key: digest.map { String(format: "%02x", $0) }.joined(),
            email: claims["email"] as? String ?? "",
            plan: auth?["chatgpt_plan_type"] as? String ?? ""
        )
    }

    /// The ChatGPT workspace (account) id inside an ID token.
    static func workspaceID(fromIDToken jwt: String) -> String? {
        let auth = (try? decodeJWTPayload(jwt))?["https://api.openai.com/auth"] as? [String: Any]
        return auth?["chatgpt_account_id"] as? String
    }

    private static func decodeJWTPayload(_ jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { throw AuthFileError.badIDToken }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthFileError.badIDToken }
        return object
    }
}
