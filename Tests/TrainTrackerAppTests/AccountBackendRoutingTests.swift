import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class AccountBackendRoutingTests: XCTestCase {
    let primary = URL(string: "https://production.example")!
    let sandbox = "https://staging.example"

    func testSandboxScopesAccountBeforeSendingAuthenticatedRequestsAndKeepsTheirPayload() async throws {
        let routing = AccountBackendRouting(primary: primary, sandboxSetting: sandbox)
        XCTAssertEqual(routing.storageSuffix, ".sandbox.staging.example")
        let transport = RecordingTransport()
        let client = AccountBackendHTTPClient(routing: routing, transport: transport)
        var request = URLRequest(url: primary.appending(path: "v1/forwarding/alias/rotate"))
        request.httpMethod = "POST"
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{}"#.utf8)
        _ = try await client.send(request)
        let captured = await transport.requests
        let sent = try XCTUnwrap(captured.first)
        XCTAssertEqual(sent.url?.absoluteString, sandbox + "/v1/forwarding/alias/rotate")
        XCTAssertEqual(sent.httpBody, request.httpBody)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(routing.storageSuffix, ".sandbox.staging.example")
        XCTAssertTrue(routing.isSelectedSandboxHost("staging.example"))
    }

    func testOrdinaryBuildUsesExistingAccountStorage() throws {
        let live = AccountBackendRouting(primary: primary, sandboxSetting: "")
        XCTAssertEqual(try live.resolve().address, primary)
        XCTAssertEqual(live.storageSuffix, "")
        XCTAssertFalse(live.isSelectedSandboxHost("staging.example"))
    }

    func testInvalidTestEndpointCannotReadOrSendProductionCredentials() async {
        let invalid = [primary.absoluteString, "http://staging.example", "https://user@staging.example", "https://staging.example/path"]
        for address in invalid {
            let routing = AccountBackendRouting(primary: primary, sandboxSetting: address)
            XCTAssertThrowsError(try routing.resolve())
            XCTAssertFalse(routing.storageSuffix.isEmpty)
            let transport = RecordingTransport()
            let client = AccountBackendHTTPClient(routing: routing, transport: transport)
            do {
                _ = try await client.send(URLRequest(url: primary.appending(path: "v1/forwarding/alias")))
                XCTFail("A misconfigured test service must fail closed")
            } catch AccountBackendRouting.RouteError.invalidTestService {} catch { XCTFail("\(error)") }
            let sent = await transport.requests
            XCTAssertTrue(sent.isEmpty)
        }
    }
}

private actor RecordingTransport: HTTPClient {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(data: Data(), statusCode: 200)
    }
}
