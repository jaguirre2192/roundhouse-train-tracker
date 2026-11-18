import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor ScriptedForwardingHTTPClient: HTTPClient {
    enum Step: Sendable {
        case response(HTTPResponse)
        case failure(URLError.Code)
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.unknown) }
        switch steps.removeFirst() {
        case let .response(response): return response
        case let .failure(code): throw URLError(code)
        }
    }
}

final class ForwardingClientTests: XCTestCase {
    private let baseURL = URL(string: "https://example.com")!

    override func tearDown() {
        AccountSessionStore.delete()
        super.tearDown()
    }

    func testAliasStatusDecodesInactiveAlias() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(
                data: Data(#"{"active":false,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                statusCode: 200
            )),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        let status = try await client.aliasStatus()

        XCTAssertFalse(status.active)
        XCTAssertNil(status.address)
        let request = await transport.requests.first
        XCTAssertEqual(request?.url?.path, "/v1/forwarding/alias")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
    }

    func testExplicitSessionTokenDoesNotFollowAChangedKeychainSession() async throws {
        try AccountSessionStore.save("token-b")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(
                data: Data(#"{"active":false,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                statusCode: 200
            )),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        _ = try await client.aliasStatus(sessionToken: "token-a")

        let request = await transport.requests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
    }

    func testCreateAliasReturnsDerivedAddress() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(
                data: Data(#"{"active":true,"address":"tickets+abc123@gettraintracker.com","createdAt":"2026-01-01T00:00:00Z","rotatedAt":"2026-01-01T00:00:00Z"}"#.utf8),
                statusCode: 200
            )),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        let status = try await client.createAlias()

        XCTAssertTrue(status.active)
        XCTAssertEqual(status.address, "tickets+abc123@gettraintracker.com")
        let request = await transport.requests.first
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/v1/forwarding/alias")
    }

    func testRotateAliasUsesRotateEndpoint() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(
                data: Data(#"{"active":true,"address":"tickets+new@gettraintracker.com","createdAt":"2026-01-01T00:00:00Z","rotatedAt":"2026-01-02T00:00:00Z"}"#.utf8),
                statusCode: 200
            )),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        _ = try await client.rotateAlias()

        let request = await transport.requests.first
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/v1/forwarding/alias/rotate")
    }

    func testRevokeAliasSendsDeleteAndAcceptsEmptyBody() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(data: Data(), statusCode: 204)),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        try await client.revokeAlias()

        let request = await transport.requests.first
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertEqual(request?.url?.path, "/v1/forwarding/alias")
    }

    func testTicketsDecodesSummaryList() async throws {
        try AccountSessionStore.save("session-token")
        let json = """
        [{"id":"t1","subject":"Your booking","sender":"tickets@amtrak.com","receivedAt":"2026-01-01T00:00:00Z",
          "operatorName":"Amtrak","trainNumber":"171","originName":null,"destinationName":null,
          "departureTime":null,"arrivalTime":null,"bookingReference":"XYZ","passengerName":null,
          "coach":null,"seat":null,"hasArtifact":true}]
        """
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(data: Data(json.utf8), statusCode: 200)),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        let tickets = try await client.tickets()

        XCTAssertEqual(tickets.count, 1)
        XCTAssertEqual(tickets.first?.trainNumber, "171")
        XCTAssertTrue(tickets.first?.hasArtifact == true)
    }

    func testDeleteTicketTargetsTicketPath() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(data: Data(), statusCode: 204)),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        try await client.deleteTicket(ticketID: "t1")

        let request = await transport.requests.first
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertEqual(request?.url?.path, "/v1/forwarding/tickets/t1")
    }

    func testArtifactUsesContentTypeHeader() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(
                data: Data("%PDF-1.4".utf8),
                statusCode: 200,
                headerFields: ["Content-Type": "application/pdf"]
            )),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        let artifact = try await client.artifact(ticketID: "t1")

        XCTAssertEqual(artifact.mimeType, "application/pdf")
        let request = await transport.requests.first
        XCTAssertEqual(request?.url?.path, "/v1/forwarding/tickets/t1/artifact")
    }

    func testArtifactSniffsTypeWhenHeaderMissing() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(data: Data([0xFF, 0xD8, 0xFF]), statusCode: 200)),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        let artifact = try await client.artifact(ticketID: "t1")

        XCTAssertEqual(artifact.mimeType, "image/jpeg")
    }

    func testArtifactNotFoundMapsFromStatus404() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(data: Data(), statusCode: 404)),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        do {
            _ = try await client.artifact(ticketID: "missing")
            XCTFail("Expected artifactNotFound")
        } catch ForwardingClient.ClientError.artifactNotFound {
            // expected
        }
    }

    func testRequestsWithoutASessionThrowSignedOut() async {
        AccountSessionStore.delete()
        let client = ForwardingClient(baseURL: baseURL, client: ScriptedForwardingHTTPClient([]))

        do {
            _ = try await client.aliasStatus()
            XCTFail("Expected signedOut")
        } catch ForwardingClient.ClientError.signedOut {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectedStatusIsSurfaced() async throws {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingHTTPClient([
            .response(HTTPResponse(data: Data(), statusCode: 500)),
        ])
        let client = ForwardingClient(baseURL: baseURL, client: transport)

        do {
            _ = try await client.aliasStatus()
            XCTFail("Expected rejected(500)")
        } catch ForwardingClient.ClientError.rejected(500) {
            // expected
        }
    }
}
