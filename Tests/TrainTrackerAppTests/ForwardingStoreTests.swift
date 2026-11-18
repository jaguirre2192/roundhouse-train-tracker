import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor ScriptedForwardingStoreHTTPClient: HTTPClient {
    enum Step: Sendable {
        case response(HTTPResponse)
        case failure(URLError.Code)
    }

    private var steps: [String: [Step]]

    init(_ steps: [String: [Step]]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        guard var remaining = steps[key], !remaining.isEmpty else {
            throw URLError(.unknown)
        }
        let step = remaining.removeFirst()
        steps[key] = remaining
        switch step {
        case let .response(response): return response
        case let .failure(code): throw URLError(code)
        }
    }
}

private actor SuspendedForwardingStoreHTTPClient: HTTPClient {
    private struct PendingRequest {
        let request: URLRequest
        let continuation: CheckedContinuation<HTTPResponse, Error>
    }

    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }

    private var pending: [PendingRequest] = []
    private var requestWaiters: [UUID: RequestWaiter] = [:]
    private(set) var observedRequests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        observedRequests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingRequest(request: request, continuation: continuation))
            let ready = requestWaiters.filter { observedRequests.count >= $0.value.count }
            for id in ready.keys { completeWaiter(id, success: true) }
        }
    }

    func waitForRequestCount(_ count: Int) async -> Bool {
        if observedRequests.count >= count { return true }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                completeWaiter(id, success: false)
            }
            requestWaiters[id] = RequestWaiter(
                count: count, continuation: continuation, timeout: timeout
            )
        }
    }

    private func completeWaiter(_ id: UUID, success: Bool) {
        guard let waiter = requestWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: success)
    }

    @discardableResult
    func resume(
        authorization: String,
        path: String,
        with response: HTTPResponse
    ) -> Bool {
        guard let index = pending.firstIndex(where: {
            $0.request.value(forHTTPHeaderField: "Authorization") == authorization
                && $0.request.url?.path == path
        }) else { return false }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: response)
        return true
    }
}

@MainActor
final class ForwardingStoreTests: XCTestCase {
    override func tearDown() {
        AccountSessionStore.delete()
        ForwardingAddressCache.clear(userID: "traveler-1")
        ForwardingAddressCache.clear(userID: "user-a")
        ForwardingAddressCache.clear(userID: "user-b")
        super.tearDown()
    }

    private func makeStore(_ steps: [String: [ScriptedForwardingStoreHTTPClient.Step]]) throws -> ForwardingStore {
        try AccountSessionStore.save("session-token")
        let transport = ScriptedForwardingStoreHTTPClient(steps)
        let client = ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        return ForwardingStore(client: client)
    }

    private func aliasResponse(address: String) -> HTTPResponse {
        HTTPResponse(
            data: Data(
                #"{"active":true,"address":"\#(address)","createdAt":null,"rotatedAt":null}"#.utf8
            ),
            statusCode: 200
        )
    }

    private func ticketsResponse(id: String, trainNumber: String) -> HTTPResponse {
        HTTPResponse(
            data: Data(
                """
                [{"id":"\(id)","subject":"Your ticket","sender":"tickets@example.com",\
                "receivedAt":"2026-01-01T00:00:00Z","operatorName":"Example Rail",\
                "trainNumber":"\(trainNumber)","originName":null,"destinationName":null,\
                "departureTime":null,"arrivalTime":null,"bookingReference":null,\
                "passengerName":null,"coach":null,"seat":null,"hasArtifact":true}]
                """.utf8
            ),
            statusCode: 200
        )
    }

    func testRiderCanCreateAndRotateAnAddressAndManageReceivedTickets() async throws {
        let attachment = Data("%PDF-1.4 roundhouse test".utf8)
        let store = try makeStore([
            "GET /v1/forwarding/alias": [.response(HTTPResponse(data: Data(#"{"active":false}"#.utf8), statusCode: 200))],
            "POST /v1/forwarding/alias": [.response(aliasResponse(address: "first@example.com"))],
            "POST /v1/forwarding/alias/rotate": [.response(aliasResponse(address: "rotated@example.com"))],
            "GET /v1/forwarding/tickets": [.response(ticketsResponse(id: "existing", trainNumber: "171"))],
            "GET /v1/forwarding/tickets/existing/artifact": [
                .response(HTTPResponse(data: attachment, statusCode: 200)),
                .response(HTTPResponse(data: Data(), statusCode: 404)),
            ],
            "DELETE /v1/forwarding/tickets/existing": [.response(HTTPResponse(data: Data(), statusCode: 204))],
            "DELETE /v1/forwarding/alias": [.response(HTTPResponse(data: Data(), statusCode: 204))],
        ])
        await store.signedIn(userID: "traveler-1")
        XCTAssertEqual(store.state, .inactive)
        await store.createAddress()
        XCTAssertEqual(store.address, "first@example.com")
        XCTAssertEqual(store.state, .active)
        await store.rotateAddress()
        XCTAssertEqual(store.address, "rotated@example.com")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.tickets.map(\.id), ["existing"])
        let saved = try await store.artifactData(ticketID: "existing")
        XCTAssertEqual(saved.data, attachment)
        await store.saveBarcode(attachment, ticketID: "existing")
        let deleted = await store.deleteTicket(id: "existing")
        XCTAssertTrue(deleted)
        XCTAssertTrue(store.tickets.isEmpty)
        let barcode = await store.cachedBarcode(ticketID: "existing")
        XCTAssertNil(barcode)
        do {
            _ = try await store.artifactData(ticketID: "existing")
            XCTFail("Deleted attachments must not be returned by the local cache.")
        } catch ForwardingClient.ClientError.artifactNotFound {}
        await store.disable()
        XCTAssertEqual(store.state, .inactive)
        XCTAssertNil(store.address)
    }

    func testStartsSignInRequiredUntilSignedIn() {
        let store = ForwardingStore()
        XCTAssertEqual(store.state, .signInRequired)
    }

    func testSignInLoadsInactiveAliasWithNoTickets() async throws {
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":false,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
            ],
            "GET /v1/forwarding/tickets": [.response(HTTPResponse(data: Data("[]".utf8), statusCode: 200))],
        ])

        await store.signedIn(userID: "traveler-1")

        XCTAssertEqual(store.state, .inactive)
        XCTAssertTrue(store.tickets.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testInactiveStatusClearsAStaleCachedAddress() async throws {
        ForwardingAddressCache.save("tickets+stale@gettraintracker.com", userID: "traveler-1")
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":false,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
            ],
            "GET /v1/forwarding/tickets": [.response(HTTPResponse(data: Data("[]".utf8), statusCode: 200))],
        ])

        await store.signedIn(userID: "traveler-1")

        XCTAssertEqual(store.state, .inactive)
        XCTAssertNil(store.address)
        XCTAssertNil(ForwardingAddressCache.load(userID: "traveler-1"))
    }

    func testInitialNetworkFailureKeepsCachedActiveAddressVisible() async throws {
        ForwardingAddressCache.save("tickets+cached@gettraintracker.com", userID: "traveler-1")
        let store = try makeStore([
            "GET /v1/forwarding/alias": [.failure(.notConnectedToInternet)],
            "GET /v1/forwarding/tickets": [.failure(.notConnectedToInternet)],
        ])

        await store.signedIn(userID: "traveler-1")

        XCTAssertEqual(store.state, .active)
        XCTAssertEqual(store.address, "tickets+cached@gettraintracker.com")
        XCTAssertNotNil(store.refreshIssue)
        XCTAssertNil(store.errorMessage, "Automatic refresh failures are never presented as action errors")
    }

    func testSignedInWithoutKeychainSessionReportsInlineIssueNotActionError() async throws {
        let store = try makeStore([:])
        AccountSessionStore.delete()

        await store.signedIn(userID: "traveler-1")

        XCTAssertEqual(store.refreshIssue, ForwardingClient.ClientError.signedOut.localizedDescription)
        XCTAssertNil(store.errorMessage, "Launch and foreground refresh must not raise a modal alert")
    }

    func testCreateAddressRevealsAndPersistsAddress() async throws {
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":false,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
            ],
            "GET /v1/forwarding/tickets": [.response(HTTPResponse(data: Data("[]".utf8), statusCode: 200))],
            "POST /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":true,"address":"tickets+abc@gettraintracker.com","createdAt":"2026-01-01T00:00:00Z","rotatedAt":"2026-01-01T00:00:00Z"}"#.utf8),
                    statusCode: 200
                )),
            ],
        ])
        await store.signedIn(userID: "traveler-1")

        await store.createAddress()

        XCTAssertEqual(store.state, .active)
        XCTAssertEqual(store.address, "tickets+abc@gettraintracker.com")
        XCTAssertEqual(ForwardingAddressCache.load(userID: "traveler-1"), "tickets+abc@gettraintracker.com")
    }

    func testDisableClearsAddressAndCache() async throws {
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":true,"address":null,"createdAt":"2026-01-01T00:00:00Z","rotatedAt":"2026-01-01T00:00:00Z"}"#.utf8),
                    statusCode: 200
                )),
            ],
            "GET /v1/forwarding/tickets": [.response(HTTPResponse(data: Data("[]".utf8), statusCode: 200))],
            "DELETE /v1/forwarding/alias": [.response(HTTPResponse(data: Data(), statusCode: 204))],
        ])
        ForwardingAddressCache.save("tickets+old@gettraintracker.com", userID: "traveler-1")
        await store.signedIn(userID: "traveler-1")
        XCTAssertEqual(store.address, "tickets+old@gettraintracker.com")

        await store.disable()

        XCTAssertEqual(store.state, .inactive)
        XCTAssertNil(store.address)
        XCTAssertNil(ForwardingAddressCache.load(userID: "traveler-1"))
    }

    func testDeleteTicketRemovesItFromTheList() async throws {
        let ticketJSON = """
        [{"id":"t1","subject":"Your booking","sender":"tickets@amtrak.com","receivedAt":"2026-01-01T00:00:00Z",
          "operatorName":"Amtrak","trainNumber":"171","originName":null,"destinationName":null,
          "departureTime":null,"arrivalTime":null,"bookingReference":null,"passengerName":null,
          "coach":null,"seat":null,"hasArtifact":false}]
        """
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":true,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
            ],
            "GET /v1/forwarding/tickets": [.response(HTTPResponse(data: Data(ticketJSON.utf8), statusCode: 200))],
            "DELETE /v1/forwarding/tickets/t1": [.response(HTTPResponse(data: Data(), statusCode: 204))],
        ])
        await store.signedIn(userID: "traveler-1")
        XCTAssertEqual(store.tickets.count, 1)

        await store.deleteTicket(id: "t1")

        XCTAssertTrue(store.tickets.isEmpty)
    }

    func testRefreshFailureAfterSuccessfulLoadKeepsKnownStateAndSurfacesError() async throws {
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":true,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
                .failure(.notConnectedToInternet),
            ],
            "GET /v1/forwarding/tickets": [
                .response(HTTPResponse(data: Data("[]".utf8), statusCode: 200)),
                .response(HTTPResponse(data: Data("[]".utf8), statusCode: 200)),
            ],
        ])
        await store.signedIn(userID: "traveler-1")
        XCTAssertEqual(store.state, .active)

        await store.refresh()

        XCTAssertEqual(store.state, .active)
        XCTAssertNotNil(store.refreshIssue)
        XCTAssertNil(store.errorMessage, "Automatic refresh failures are never presented as action errors")
    }

    func testRepeatedSignInForSameUserRefreshesForwardedTickets() async throws {
        let ticketJSON = """
        [{"id":"t1","subject":"Your booking","sender":"tickets@amtrak.com","receivedAt":"2026-01-01T00:00:00Z",
          "operatorName":"Amtrak","trainNumber":"171","originName":null,"destinationName":null,
          "departureTime":null,"arrivalTime":null,"bookingReference":null,"passengerName":null,
          "coach":null,"seat":null,"hasArtifact":false}]
        """
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":true,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
                .response(HTTPResponse(
                    data: Data(#"{"active":true,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
            ],
            "GET /v1/forwarding/tickets": [
                .response(HTTPResponse(data: Data("[]".utf8), statusCode: 200)),
                .response(HTTPResponse(data: Data(ticketJSON.utf8), statusCode: 200)),
            ],
        ])
        await store.signedIn(userID: "traveler-1")
        XCTAssertTrue(store.tickets.isEmpty)

        await store.signedIn(userID: "traveler-1")

        XCTAssertEqual(store.tickets.map(\.id), ["t1"])
        XCTAssertNil(store.errorMessage)
    }

    func testSignOutResetsState() async throws {
        let store = try makeStore([
            "GET /v1/forwarding/alias": [
                .response(HTTPResponse(
                    data: Data(#"{"active":true,"address":"tickets+abc@gettraintracker.com","createdAt":null,"rotatedAt":null}"#.utf8),
                    statusCode: 200
                )),
            ],
            "GET /v1/forwarding/tickets": [.response(HTTPResponse(data: Data("[]".utf8), statusCode: 200))],
        ])
        await store.signedIn(userID: "traveler-1")
        XCTAssertEqual(store.state, .active)

        store.signedOut()

        XCTAssertEqual(store.state, .signInRequired)
        XCTAssertNil(store.address)
        XCTAssertTrue(store.tickets.isEmpty)
    }

    func testSignOutInvalidatesAnInFlightRefresh() async throws {
        try AccountSessionStore.save("token-a")
        let transport = SuspendedForwardingStoreHTTPClient()
        let store = ForwardingStore(
            client: ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        )
        let signIn = Task { await store.signedIn(userID: "user-a") }
        let started = await transport.waitForRequestCount(2)
        XCTAssertTrue(started)

        store.signedOut()
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+a@gettraintracker.com")
        )
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets",
            with: ticketsResponse(id: "ticket-a", trainNumber: "171")
        )
        await signIn.value

        XCTAssertEqual(store.state, .signInRequired)
        XCTAssertNil(store.address)
        XCTAssertTrue(store.tickets.isEmpty)
        XCTAssertFalse(store.isWorking)
    }

    func testDeletingTheKeychainSessionInvalidatesAnInFlightRefreshBeforeLifecycleDelivery() async throws {
        try AccountSessionStore.save("token-a")
        let transport = SuspendedForwardingStoreHTTPClient()
        let store = ForwardingStore(
            client: ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        )
        let signIn = Task { await store.signedIn(userID: "user-a") }
        let started = await transport.waitForRequestCount(2)
        XCTAssertTrue(started)

        AccountSessionStore.delete()
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+a@gettraintracker.com")
        )
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets",
            with: ticketsResponse(id: "ticket-a", trainNumber: "171")
        )
        await signIn.value

        XCTAssertNil(store.address)
        XCTAssertTrue(store.tickets.isEmpty)
        XCTAssertFalse(store.isWorking)
    }

    func testAccountSwitchUsesTheNewTokenAndRejectsTheOldCompletion() async throws {
        try AccountSessionStore.save("token-a")
        let transport = SuspendedForwardingStoreHTTPClient()
        let store = ForwardingStore(
            client: ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        )
        let firstSignIn = Task { await store.signedIn(userID: "user-a") }
        let refreshStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(refreshStarted)

        try AccountSessionStore.save("token-b")
        let secondSignIn = Task { await store.signedIn(userID: "user-b") }
        let startedSecondSession = await transport.waitForRequestCount(4)

        if startedSecondSession {
            await transport.resume(
                authorization: "Bearer token-b",
                path: "/v1/forwarding/alias",
                with: aliasResponse(address: "tickets+b@gettraintracker.com")
            )
            await transport.resume(
                authorization: "Bearer token-b",
                path: "/v1/forwarding/tickets",
                with: ticketsResponse(id: "ticket-b", trainNumber: "225")
            )
        }
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+a@gettraintracker.com")
        )
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets",
            with: ticketsResponse(id: "ticket-a", trainNumber: "171")
        )
        await firstSignIn.value
        await secondSignIn.value

        XCTAssertTrue(startedSecondSession)
        XCTAssertEqual(store.state, .active)
        XCTAssertEqual(store.address, "tickets+b@gettraintracker.com")
        XCTAssertEqual(store.tickets.map(\.id), ["ticket-b"])
        XCTAssertFalse(store.isWorking)
    }

    func testSignOutInvalidatesAnInFlightAliasMutation() async throws {
        try AccountSessionStore.save("token-a")
        let transport = SuspendedForwardingStoreHTTPClient()
        let store = ForwardingStore(
            client: ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        )
        let signIn = Task { await store.signedIn(userID: "user-a") }
        let firstRefreshStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(firstRefreshStarted)
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/alias",
            with: HTTPResponse(
                data: Data(#"{"active":false,"address":null,"createdAt":null,"rotatedAt":null}"#.utf8),
                statusCode: 200
            )
        )
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets",
            with: HTTPResponse(data: Data("[]".utf8), statusCode: 200)
        )
        await signIn.value

        let create = Task { await store.createAddress() }
        let secondRefreshStarted = await transport.waitForRequestCount(3)
        XCTAssertTrue(secondRefreshStarted)
        store.signedOut()
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+a@gettraintracker.com")
        )
        await create.value

        XCTAssertEqual(store.state, .signInRequired)
        XCTAssertNil(store.address)
    }

    func testSignOutRejectsAnInFlightArtifactResponse() async throws {
        try AccountSessionStore.save("token-a")
        let transport = SuspendedForwardingStoreHTTPClient()
        let store = ForwardingStore(
            client: ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        )
        let signIn = Task { await store.signedIn(userID: "user-a") }
        let mutationStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(mutationStarted)
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+a@gettraintracker.com")
        )
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets",
            with: ticketsResponse(id: "ticket-a", trainNumber: "171")
        )
        await signIn.value

        let artifact = Task { () -> Result<(data: Data, mimeType: String), Error> in
            do {
                return .success(try await store.artifactData(ticketID: "ticket-a"))
            } catch {
                return .failure(error)
            }
        }
        let artifactRequestStarted = await transport.waitForRequestCount(3)
        XCTAssertTrue(artifactRequestStarted)
        store.signedOut()
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets/ticket-a/artifact",
            with: HTTPResponse(
                data: Data("%PDF-1.4".utf8),
                statusCode: 200,
                headerFields: ["Content-Type": "application/pdf"]
            )
        )

        switch await artifact.value {
        case .success:
            XCTFail("A signed-out session must not receive or cache an old account artifact")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testReplacingTheKeychainSessionRejectsAnInFlightArtifactBeforeLifecycleDelivery() async throws {
        try AccountSessionStore.save("token-a")
        let transport = SuspendedForwardingStoreHTTPClient()
        let store = ForwardingStore(
            client: ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        )
        let signIn = Task { await store.signedIn(userID: "user-a") }
        let refreshStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(refreshStarted)
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+a@gettraintracker.com")
        )
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets",
            with: ticketsResponse(id: "shared-ticket", trainNumber: "171")
        )
        await signIn.value

        let artifact = Task { () -> Result<(data: Data, mimeType: String), Error> in
            do {
                return .success(try await store.artifactData(ticketID: "shared-ticket"))
            } catch {
                return .failure(error)
            }
        }
        let artifactStarted = await transport.waitForRequestCount(3)
        XCTAssertTrue(artifactStarted)
        try AccountSessionStore.save("token-b")
        await transport.resume(
            authorization: "Bearer token-a",
            path: "/v1/forwarding/tickets/shared-ticket/artifact",
            with: HTTPResponse(
                data: Data("%PDF-1.4".utf8),
                statusCode: 200,
                headerFields: ["Content-Type": "application/pdf"]
            )
        )

        switch await artifact.value {
        case .success:
            XCTFail("A replaced session must not receive or cache the prior session's artifact")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPersistentBarcodeCacheIsScopedAcrossAccountSwitches() async throws {
        let firstToken = "token-a-\(UUID().uuidString)"
        let secondToken = "token-b-\(UUID().uuidString)"
        let ticketID = "shared-ticket-\(UUID().uuidString)"
        try AccountSessionStore.save(firstToken)
        let transport = SuspendedForwardingStoreHTTPClient()
        let store = ForwardingStore(
            client: ForwardingClient(baseURL: URL(string: "https://example.com")!, client: transport)
        )
        let firstSignIn = Task { await store.signedIn(userID: "user-a") }
        let firstRefreshStarted = await transport.waitForRequestCount(2)
        XCTAssertTrue(firstRefreshStarted)
        await transport.resume(
            authorization: "Bearer \(firstToken)",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+a@gettraintracker.com")
        )
        await transport.resume(
            authorization: "Bearer \(firstToken)",
            path: "/v1/forwarding/tickets",
            with: ticketsResponse(id: ticketID, trainNumber: "171")
        )
        await firstSignIn.value

        let barcode = Data([0x01, 0x02, 0x03])
        await store.saveBarcode(barcode, ticketID: ticketID)
        let firstAccountBarcode = await store.cachedBarcode(ticketID: ticketID)
        XCTAssertEqual(firstAccountBarcode, barcode)

        try AccountSessionStore.save(secondToken)
        let secondSignIn = Task { await store.signedIn(userID: "user-b") }
        let secondRefreshStarted = await transport.waitForRequestCount(4)
        XCTAssertTrue(secondRefreshStarted)
        await transport.resume(
            authorization: "Bearer \(secondToken)",
            path: "/v1/forwarding/alias",
            with: aliasResponse(address: "tickets+b@gettraintracker.com")
        )
        await transport.resume(
            authorization: "Bearer \(secondToken)",
            path: "/v1/forwarding/tickets",
            with: ticketsResponse(id: ticketID, trainNumber: "225")
        )
        await secondSignIn.value

        let secondAccountBarcode = await store.cachedBarcode(ticketID: ticketID)
        XCTAssertNil(secondAccountBarcode)
    }
}
