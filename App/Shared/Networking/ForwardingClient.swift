import Foundation
import TrainTrackerCore

/// Talks to the `/v1/forwarding/*` API. Authenticates the same way every other authenticated
/// client in this app does — a bearer token read from `AccountSessionStore` — and that token is
/// never written anywhere the Share extension's App Group container could see it.
actor ForwardingClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case signedOut
        case artifactNotFound
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Ticket forwarding is temporarily unavailable."
            case .signedOut: "Please sign in again."
            case .artifactNotFound: "That ticket is no longer available."
            case .rejected(401): "Please sign in again."
            case .rejected(404): "That ticket is no longer available."
            case .rejected: "We could not complete that request. Please try again."
            }
        }
    }

    private struct EmptyResponse: Decodable {}

    private let baseURL: URL?
    private let client: any HTTPClient

    init(
        baseURL: URL? = TrainTrackerBackendConfiguration.baseURL,
        client: any HTTPClient = AccountBackendHTTPClient()
    ) {
        self.baseURL = baseURL
        self.client = client
    }

    func aliasStatus() async throws -> ForwardingAliasStatus {
        try await aliasStatus(sessionToken: sessionToken())
    }

    func aliasStatus(sessionToken: String) async throws -> ForwardingAliasStatus {
        try await request(path: "v1/forwarding/alias", sessionToken: sessionToken)
    }

    func createAlias() async throws -> ForwardingAliasStatus {
        try await createAlias(sessionToken: sessionToken())
    }

    func createAlias(sessionToken: String) async throws -> ForwardingAliasStatus {
        try await request(path: "v1/forwarding/alias", method: "POST", sessionToken: sessionToken)
    }

    func rotateAlias() async throws -> ForwardingAliasStatus {
        try await rotateAlias(sessionToken: sessionToken())
    }

    func rotateAlias(sessionToken: String) async throws -> ForwardingAliasStatus {
        try await request(path: "v1/forwarding/alias/rotate", method: "POST", sessionToken: sessionToken)
    }

    func revokeAlias() async throws {
        try await revokeAlias(sessionToken: sessionToken())
    }

    func revokeAlias(sessionToken: String) async throws {
        let _: EmptyResponse = try await request(
            path: "v1/forwarding/alias",
            method: "DELETE",
            sessionToken: sessionToken
        )
    }

    func tickets() async throws -> [ForwardedTicketSummary] {
        try await tickets(sessionToken: sessionToken())
    }

    func tickets(sessionToken: String) async throws -> [ForwardedTicketSummary] {
        try await request(path: "v1/forwarding/tickets", sessionToken: sessionToken)
    }

    func deleteTicket(ticketID: String) async throws {
        try await deleteTicket(ticketID: ticketID, sessionToken: sessionToken())
    }

    func deleteTicket(ticketID: String, sessionToken: String) async throws {
        let _: EmptyResponse = try await request(
            path: "v1/forwarding/tickets/\(ticketID)",
            method: "DELETE",
            sessionToken: sessionToken
        )
    }

    func artifact(ticketID: String) async throws -> (data: Data, mimeType: String) {
        try await artifact(ticketID: ticketID, sessionToken: sessionToken())
    }

    func artifact(ticketID: String, sessionToken: String) async throws -> (data: Data, mimeType: String) {
        guard let baseURL else { throw ClientError.notConfigured }
        var request = URLRequest(
            url: baseURL.appending(path: "v1/forwarding/tickets/\(ticketID)/artifact"),
            timeoutInterval: 30
        )
        authorize(&request, sessionToken: sessionToken)
        let response = try await client.send(request)
        guard response.statusCode == 200 else {
            throw response.statusCode == 404 ? ClientError.artifactNotFound : ClientError.rejected(response.statusCode)
        }
        let mimeType = ForwardedArtifactMimeSniffer.mimeType(
            headerValue: response.value(forHTTPHeaderField: "Content-Type"),
            data: response.data
        )
        return (response.data, mimeType)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        sessionToken: String
    ) async throws -> Response {
        guard let baseURL else { throw ClientError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request, sessionToken: sessionToken)
        let response = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.rejected(response.statusCode)
        }
        if Response.self == EmptyResponse.self, response.data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try JSONDecoder().decode(Response.self, from: response.data)
    }

    private func sessionToken() throws -> String {
        guard let sessionToken = AccountSessionStore.load() else { throw ClientError.signedOut }
        return sessionToken
    }

    private func authorize(_ request: inout URLRequest, sessionToken: String) {
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }
}
