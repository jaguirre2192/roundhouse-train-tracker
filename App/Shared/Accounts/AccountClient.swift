import Foundation
import TrainTrackerCore

actor AccountClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case invalidCallback
        case signedOut
        case rejected(Int, String?)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Account sign-in is temporarily unavailable."
            case .invalidCallback: "The sign-in could not be verified. Please try again."
            case .signedOut: "Please sign in again."
            case .rejected(409, _): "That sign-in is already linked to another account."
            case .rejected(503, "apple_sign_in_unavailable"):
                "Sign in with Apple is temporarily unavailable. You can continue as a guest and try again later."
            case .rejected(401, "apple_identity_verification_failed"):
                "Apple could not verify this sign-in. Please try again."
            case .rejected(502, "apple_code_exchange_failed"):
                "Apple sign-in could not finish securely. Please try again."
            case .rejected(_, "invalid_apple_credential"):
                "Apple did not return a valid sign-in credential. Please try again."
            case .rejected:
                "We could not complete sign-in. Please try again."
            }
        }
    }

    private struct AuthorizationResponse: Decodable { let url: URL }
    private struct StartBody: Encodable { let transactionId: String; let challenge: String }
    private struct ExchangeBody: Encodable { let code: String; let transactionId: String; let verifier: String }
    private struct AppleBody: Encodable {
        let identityToken: String
        let authorizationCode: String
        let rawNonce: String
        let fullName: String?
    }
    private struct SessionResponse: Decodable { let token: String; let user: AppUser }
    private struct MeResponse: Decodable { let user: AppUser }
    private struct EmptyResponse: Decodable {}

    private let baseURL: URL?
    private let client: any HTTPClient
    private let routing: AccountBackendRouting

    init(
        baseURL: URL? = TrainTrackerBackendConfiguration.baseURL,
        client: any HTTPClient = AccountBackendHTTPClient(),
        routing: AccountBackendRouting = .shared
    ) {
        self.baseURL = baseURL
        self.client = client
        self.routing = routing
    }

    func restoreUser() async throws -> AppUser? {
        try routing.resolve()
        guard let sessionToken = AccountSessionStore.load() else { return nil }
        var request = try makeRequest(path: "v1/auth/me", method: "GET", authenticated: false)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        do {
            let response: MeResponse = try await send(request)
            return response.user
        } catch ClientError.rejected(401, _) {
            if AccountSessionStore.load() == sessionToken {
                AccountSessionStore.delete()
            }
            return nil
        }
    }

    func googleAuthorizationURL() async throws -> URL {
        try routing.resolve()
        let handoff = try OAuthHandoffStore.create(for: .accountGoogle)
        let response: AuthorizationResponse = try await request(
            path: "v1/auth/google/start",
            method: "POST",
            body: StartBody(transactionId: handoff.transactionID, challenge: handoff.challenge),
            authenticated: AccountSessionStore.load() != nil
        )
        return response.url
    }

    func completeGoogleSignIn(from url: URL) async throws -> AppUser {
        try routing.resolve()
        guard Self.isCallback(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let transactionID = components.queryItems?.first(where: { $0.name == "transaction" })?.value,
              let handoff = OAuthHandoffStore.load(for: .accountGoogle),
              handoff.transactionID == transactionID else {
            throw ClientError.invalidCallback
        }
        defer { OAuthHandoffStore.delete(for: .accountGoogle) }
        let response: SessionResponse = try await request(
            path: "v1/auth/session/exchange",
            method: "POST",
            body: ExchangeBody(code: code, transactionId: transactionID, verifier: handoff.verifier),
            authenticated: false
        )
        try AccountSessionStore.save(response.token)
        return response.user
    }

    func signInWithApple(
        identityToken: String,
        authorizationCode: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AppUser {
        try routing.resolve()
        let response: SessionResponse = try await request(
            path: "v1/auth/apple",
            method: "POST",
            body: AppleBody(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                rawNonce: rawNonce,
                fullName: fullName
            ),
            authenticated: AccountSessionStore.load() != nil
        )
        try AccountSessionStore.save(response.token)
        return response.user
    }

    func logout() async {
        if AccountSessionStore.load() != nil {
            let _: EmptyResponse? = try? await request(path: "v1/auth/logout", method: "POST")
        }
        clearLocalSession()
    }

    func deleteAccount() async throws {
        try routing.resolve()
        let _: EmptyResponse = try await request(path: "v1/auth/account", method: "DELETE")
        clearLocalSession()
    }

    private func clearLocalSession() {
        AccountSessionStore.delete()
        OAuthHandoffStore.delete(for: .accountGoogle)
        OAuthHandoffStore.delete(for: .gmail)
    }

    nonisolated static func isCallback(_ url: URL) -> Bool {
        if url.scheme == "traintracker", url.host == "auth-connected" { return true }
        return TrainTrackerBackendConfiguration.isTrustedCallback(url, path: "/auth-connected")
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method, authenticated: authenticated)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        authenticated: Bool = true
    ) async throws -> Response {
        try await send(makeRequest(path: path, method: method, authenticated: authenticated))
    }

    private func makeRequest(path: String, method: String, authenticated: Bool) throws -> URLRequest {
        guard let baseURL else { throw ClientError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let token = AccountSessionStore.load() else { throw ClientError.signedOut }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let response = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: response.data)
            throw ClientError.rejected(response.statusCode, serverError?.error)
        }
        if Response.self == EmptyResponse.self, response.data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try JSONDecoder().decode(Response.self, from: response.data)
    }

    private struct ServerErrorResponse: Decodable {
        let error: String
    }
}
