import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor ReferenceHTTPClient: HTTPClient {
    private(set) var requests: [URLRequest] = []
    let emptySnapshot: Bool

    init(emptySnapshot: Bool = false) { self.emptySnapshot = emptySnapshot }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url?.path == "/v1/stations/board" {
            return HTTPResponse(data: Data("[]".utf8), statusCode: 200)
        }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = query.first { $0.name == "id" }?.value ?? ""
        let source = query.first { $0.name == "source" }?.value ?? ""
        return HTTPResponse(data: try TripSnapshotReferenceTests.snapshot(
            id: id, source: source, empty: emptySnapshot
        ), statusCode: 200)
    }
}

final class TripSnapshotReferenceTests: XCTestCase {
    private let serviceDate = Date(timeIntervalSince1970: 1_794_528_000)

    func testLegacyAmtrakStationUsesBackendWithSourceHint() async throws {
        let http = ReferenceHTTPClient()
        let backend = try client(http)

        let values = try await backend.board(
            stationID: RailIdentifier(rawValue: "NYP"), at: serviceDate,
            direction: .departures, source: .unitedStates
        )

        XCTAssertTrue(values.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let query = try query(requests.first)
        XCTAssertEqual(query["stationId"], "us:amtraker:NYP")
        XCTAssertEqual(query["source"], "amtraker")
        XCTAssertEqual(query["nativeId"], "NYP")
    }

    func testLegacyTransitousTripKeepsItsCompleteColonBearingNativeID() async throws {
        let http = ReferenceHTTPClient()
        let backend = try client(http)
        let nativeID = "20261113_17:03_ch-opentransportdataswiss26_.ojp:91:2"

        let trip = try await backend.trip(
            id: RailIdentifier(rawValue: nativeID), serviceDate: serviceDate, source: .europe
        )

        let requests = await http.requests
        let query = try query(requests.first)
        XCTAssertEqual(query["id"], "eu:transitous:\(nativeID)")
        XCTAssertEqual(query["nativeId"], nativeID)
        XCTAssertEqual(query["source"], "transitous")
        XCTAssertEqual(query["serviceDate"], "2026-11-13")
        XCTAssertEqual(trip.id.rawValue, "eu:transitous:\(nativeID)")
    }

    func testRefreshOfLegacyTripPreservesSavedIdentityAndFullNativeID() async throws {
        let http = ReferenceHTTPClient()
        let backend = try client(http)
        let nativeID = "20261113_17:03_ch-opentransportdataswiss26_.ojp:91:2"
        let saved = try JSONDecoder().decode(BackendTripSnapshot.self, from: Self.snapshot(
            id: nativeID, source: "transitous"
        )).trip

        let refreshed = try await backend.enrichedTrip(saved)

        XCTAssertEqual(refreshed.id, saved.id)
        XCTAssertEqual(refreshed.serviceDate, saved.serviceDate)
        let requests = await http.requests
        let query = try query(requests.first)
        XCTAssertEqual(query["nativeId"], nativeID)
        XCTAssertEqual(query["source"], "transitous")
    }

    func testCanonicalProviderOverridesDiscoveryScopeHintAndPreservesNativeColons() async throws {
        let http = ReferenceHTTPClient()
        let backend = try client(http)

        _ = try await backend.trip(
            id: RailIdentifier(rawValue: "tw:tdx:TRA:123"),
            serviceDate: serviceDate, source: .europe
        )
        _ = try await backend.board(
            stationID: RailIdentifier(rawValue: "rs:srbijavoz:16052"),
            at: serviceDate, direction: .arrivals, source: .europe
        )

        let requests = await http.requests
        let tripQuery = try query(requests.first)
        XCTAssertEqual(tripQuery["source"], "tdx")
        XCTAssertEqual(tripQuery["nativeId"], "TRA:123")
        let boardQuery = try query(requests.last)
        XCTAssertEqual(boardQuery["source"], "srbijavoz")
        XCTAssertEqual(boardQuery["nativeId"], "16052")
        XCTAssertEqual(boardQuery["direction"], "arrivals")
    }

    func testSavedNorthAmericanTransitousNamespacesKeepTheirProvider() async throws {
        let http = ReferenceHTTPClient()
        let backend = try client(http)
        for region in ["us", "ca"] {
            let id = "\(region):transitous:20261113_17:03_\(region)-Amtrak_171"
            let saved = try JSONDecoder().decode(BackendTripSnapshot.self, from: Self.snapshot(
                id: id, source: "transitous"
            )).trip
            let refreshed = try await backend.enrichedTrip(saved)
            XCTAssertEqual(refreshed.id.rawValue, id)
        }

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        for (request, region) in zip(requests, ["us", "ca"]) {
            let query = try query(request)
            XCTAssertEqual(query["source"], "transitous")
            XCTAssertEqual(query["nativeId"], "20261113_17:03_\(region)-Amtrak_171")
            XCTAssertEqual(query["id"], "\(region):transitous:20261113_17:03_\(region)-Amtrak_171")
        }
    }

    func testMalformedNamespacesAndUnhintedRawReferencesFailBeforeTransport() async throws {
        let http = ReferenceHTTPClient()
        let backend = try client(http)
        for (id, source) in [
            ("eu:transitous:", RailSource.europe),
            ("invalid:transitous:123", RailSource.europe),
            ("eu:unsupported:123", RailSource.europe),
            ("  ", RailSource.unitedStates),
        ] {
            do {
                _ = try await backend.trip(id: RailIdentifier(rawValue: id), serviceDate: serviceDate, source: source)
                XCTFail("Accepted malformed reference \(id)")
            } catch TripSnapshotBackendClient.ClientError.invalidRequest {} catch { XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await backend.trip(id: RailIdentifier(rawValue: "171-13"), serviceDate: serviceDate)
            XCTFail("Raw references require a provider hint")
        } catch TripSnapshotBackendClient.ClientError.invalidRequest {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRefreshRejectsConflictingSavedSourceBeforeTransport() async throws {
        let http = ReferenceHTTPClient()
        let backend = try client(http)
        let saved = try JSONDecoder().decode(BackendTripSnapshot.self, from: Self.snapshot(
            id: "us:amtraker:171-13", source: "transitous"
        )).trip

        do {
            _ = try await backend.enrichedTrip(saved)
            XCTFail("The saved source and canonical namespace must agree")
        } catch TripSnapshotBackendClient.ClientError.invalidRequest {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEmptySuccessfulSnapshotIsRejectedForAdditionAndRefresh() async throws {
        let http = ReferenceHTTPClient(emptySnapshot: true)
        let backend = try client(http)
        let saved = try JSONDecoder().decode(BackendTripSnapshot.self, from: Self.snapshot()).trip

        do {
            _ = try await backend.trip(id: saved.id, serviceDate: saved.serviceDate)
            XCTFail("An empty snapshot cannot become a tracked train")
        } catch TripSnapshotBackendClient.ClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await backend.enrichedTrip(saved)
            XCTFail("An empty snapshot cannot erase a saved route")
        } catch TripSnapshotBackendClient.ClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func client(_ http: ReferenceHTTPClient) throws -> TripSnapshotBackendClient {
        TripSnapshotBackendClient(baseURL: try XCTUnwrap(URL(string: "https://backend.test")), client: http)
    }

    private func query(_ request: URLRequest?) throws -> [String: String] {
        let url = try XCTUnwrap(request?.url)
        XCTAssertEqual(url.host, "backend.test")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    fileprivate static func snapshot(
        id: String = "eu:transitous:20261113_test", source: String = "transitous", empty: Bool = false
    ) throws -> Data {
        let stop: [String: Any] = [
            "stationId": "eu:transitous:origin", "stationName": "Origin", "countryCode": "CH",
            "latitude": 47.0, "longitude": 8.0, "sequence": 1,
            "scheduledDeparture": "2026-11-13T16:03:00Z", "cancelled": false, "passed": false,
        ]
        return try JSONSerialization.data(withJSONObject: [
            "id": id, "source": source, "serviceDate": "2026-11-13",
            "operatorName": "Test Rail", "product": "R2", "headsign": "Destination",
            "fetchedAt": "2026-11-13T15:00:00Z", "stops": empty ? [] : [stop],
        ])
    }
}
