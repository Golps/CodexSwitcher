import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Network

/// Signs in a ChatGPT account the same way `codex login` does (OAuth with PKCE
/// against auth.openai.com), but in a private browser session that remembers
/// nothing, so it never picks up the account you're already signed in to.
/// Returns the contents of a Codex auth.json for the new account.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    // Codex's public sign-in client and callback, as used by `codex login`.
    nonisolated static let issuer = "https://auth.openai.com"
    nonisolated static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let port: UInt16 = 1455
    private static let redirectURI = "http://127.0.0.1:1455/auth/callback"

    private let verifier = WebSignIn.randomToken(bytes: 64)
    private let state = WebSignIn.randomToken(bytes: 32)
    private var listener: NWListener?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<String, Error>?
    nonisolated(unsafe) private var anchor: NSWindow!

    override init() {
        super.init()
        anchor = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    }

    /// The sign-in page, for copying into another browser if needed.
    var link: URL {
        var parts = URLComponents(string: "\(Self.issuer)/oauth/authorize")!
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        parts.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        // URLComponents leaves "+" alone, but form decoders read it as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    func run() async throws -> Data {
        defer { stop() }
        let code: String = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do { try startListener() } catch {
                finish(.failure(SignInError.portBusy))
                return
            }
            let session = ASWebAuthenticationSession(url: link, callbackURLScheme: "codexswitcher") { _, error in
                // The window closing on its own (not because we got the code) means the user cancelled.
                Task { @MainActor in
                    if error != nil { self.finish(.failure(CancellationError())) }
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { finish(.failure(SignInError.couldNotOpen)) }
        }
        return try await exchange(code: code)
    }

    func cancel() { finish(.failure(CancellationError())) }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }

    // MARK: Callback listener

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        // These closures hold self only until stop() cancels and drops the listener.
        listener.newConnectionHandler = { connection in
            Task { @MainActor in self.handle(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state { Task { @MainActor in self.finish(.failure(SignInError.portBusy)) } }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            Task { @MainActor in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let url = URLComponents(string: "http://127.0.0.1\(target)")
                let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                       uniquingKeysWith: { first, _ in first })

                guard url?.path == "/auth/callback" else {
                    self.respond(connection, status: "404 Not Found", message: "Not found.")
                    return
                }
                if let error = query["error"] {
                    self.respond(connection, status: "200 OK", message: "Sign-in didn't finish. You can close this window.")
                    self.finish(.failure(SignInError.rejected(query["error_description"] ?? error)))
                } else if query["state"]?.hasPrefix(self.state) == true, let code = query["code"], !code.isEmpty {
                    self.respond(connection, status: "200 OK", message: "Signed in. You can close this window.")
                    self.finish(.success(code))
                } else {
                    self.respond(connection, status: "400 Bad Request", message: "This sign-in link has expired. Start again from Codex Switcher.")
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let body = "<!doctype html><meta charset=utf-8><title>Codex Switcher</title>"
            + "<body style=\"font:16px -apple-system;text-align:center;padding-top:80px\">\(message)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(with: result)
    }

    private func stop() {
        listener?.cancel(); listener = nil
        session?.cancel(); session = nil
    }

    // MARK: Token exchange

    private func exchange(code: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", Self.clientID),
            ("code", code),
            ("redirect_uri", Self.redirectURI),
            ("code_verifier", verifier),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String
        else { throw SignInError.rejected(String(decoding: data.prefix(300), as: UTF8.self)) }

        // Same layout Codex writes to ~/.codex/auth.json after `codex login`.
        let auth: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": idToken,
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": AuthFile.workspaceID(fromIDToken: idToken) ?? NSNull(),
            ] as [String: Any],
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ]
        return try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
    }

    private static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}

enum SignInError: LocalizedError {
    case portBusy
    case couldNotOpen
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .portBusy:
            return "Another sign-in is already running (Codex may be signing in). Finish or close it, then try again."
        case .couldNotOpen:
            return "Couldn't open the sign-in window. Try again."
        case .rejected(let detail):
            return "OpenAI didn't accept the sign-in. \(detail)"
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
