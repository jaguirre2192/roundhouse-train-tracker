import Foundation
import TrainTrackerCore

actor GmailInboxClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case invalidCallback
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Gmail import is not available yet."
            case .invalidCallback: "Google did not return a valid connection."
            case .rejected(401): "Please sign in again before connecting Gmail."
            case .rejected(409): "That Gmail inbox is already connected to another account."
            case .rejected(429): "Gmail was checked recently. Try again in a few minutes."
            case .rejected: "Gmail import could not be completed."
            }
        }
    }

    private struct AuthorizationResponse: Decodable { let url: URL }
    private struct StartBody: Encodable { let transactionId: String; let challenge: String }
    private struct ExchangeBody: Encodable { let code: String; let transactionId: String; let verifier: String }
    private struct ExchangeResponse: Decodable { let connected: Bool }
    private struct ScanResponse: Decodable { let imported: Int }

    private let baseURL: URL?
    private let client: any HTTPClient

    init(
        baseURL: URL? = TrainTrackerBackendConfiguration.baseURL,
        client: any HTTPClient = AccountBackendHTTPClient()
    ) {
        self.baseURL = baseURL
        self.client = client
    }

    func hasSession() -> Bool { AccountSessionStore.load() != nil }

    func authorizationURL() async throws -> URL {
        let handoff = try OAuthHandoffStore.create(for: .gmail)
        let response: AuthorizationResponse = try await request(
            path: "v1/gmail/oauth/start",
            method: "POST",
            body: StartBody(transactionId: handoff.transactionID, challenge: handoff.challenge)
        )
        return response.url
    }

    func completeConnection(from url: URL) async throws {
        guard TicketInbox.isCallback(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let transactionID = components.queryItems?.first(where: { $0.name == "transaction" })?.value,
              let handoff = OAuthHandoffStore.load(for: .gmail),
              handoff.transactionID == transactionID else {
            throw ClientError.invalidCallback
        }
        defer { OAuthHandoffStore.delete(for: .gmail) }
        let response: ExchangeResponse = try await request(
            path: "v1/gmail/session/exchange",
            method: "POST",
            body: ExchangeBody(code: code, transactionId: transactionID, verifier: handoff.verifier)
        )
        guard response.connected else { throw ClientError.invalidCallback }
    }

    func connections() async throws -> [GmailConnection] {
        try await request(path: "v1/gmail/connections")
    }

    func tickets() async throws -> [TrainTicket] {
        try await request(path: "v1/gmail/tickets")
    }

    func scan() async throws -> Int {
        let response: ScanResponse = try await request(path: "v1/gmail/scan", method: "POST")
        return response.imported
    }

    func artifact(ticketID: String) async throws -> Data {
        guard let baseURL else { throw ClientError.notConfigured }
        var request = URLRequest(
            url: baseURL.appending(path: "v1/gmail/tickets/\(ticketID)/artifact"),
            timeoutInterval: 30
        )
        try authorize(&request)
        let response = try await client.send(request)
        guard response.statusCode == 200 else { throw ClientError.rejected(response.statusCode) }
        return response.data
    }

    func disconnect(_ connection: GmailConnection) async throws {
        let _: EmptyResponse = try await request(
            path: "v1/gmail/connections/\(connection.id)",
            method: "DELETE"
        )
    }

    private struct EmptyResponse: Decodable {}

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        guard let baseURL else { throw ClientError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if authenticated { try authorize(&request) }
        return try await send(request)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        authenticated: Bool = true
    ) async throws -> Response {
        guard let baseURL else { throw ClientError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated { try authorize(&request) }
        return try await send(request)
    }

    private func authorize(_ request: inout URLRequest) throws {
        guard let sessionToken = AccountSessionStore.load() else { throw ClientError.rejected(401) }
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let response = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.rejected(response.statusCode)
        }
        if Response.self == EmptyResponse.self, response.data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try JSONDecoder().decode(Response.self, from: response.data)
    }
}
