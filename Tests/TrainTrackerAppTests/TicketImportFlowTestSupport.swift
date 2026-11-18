import Foundation
import TrainTrackerCore
@testable import TrainTracker

/// Only the HTTP boundary is substituted. Parsing, HTTP codecs, matching, persistence and
/// snapshot merging all use the production implementations in the integration test.
actor TicketImportFlowHTTPClient: HTTPClient {
    private(set) var searchRequests: [URLRequest] = []
    private var failedResolution = false

    static let origin = JourneySearchStoreFixtures.place(id: "eu:transitous:paris-lyon", name: "Paris Gare de Lyon", kind: .station)
    static let destination = JourneySearchStoreFixtures.place(id: "eu:transitous:lyon", name: "Lyon Part Dieu", kind: .station)
    static let tripID = RailIdentifier(rawValue: "eu:transitous:tgv-6611-20261114")
    static let departure = JourneySearchStoreFixtures.date("2026-11-14T14:00:00Z")
    static let arrival = JourneySearchStoreFixtures.date("2026-11-14T16:00:00Z")

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        switch request.url?.path {
        case "/v1/places/search":
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            let places = [Self.origin, Self.destination].filter { $0.displayName == query }
            return try encoded(places)
        case "/v1/journeys/search":
            searchRequests.append(request)
            let option = JourneySearchStoreFixtures.option(
                id: "outbound", fingerprint: "paris-lyon-6611-20261114", start: Self.departure, end: Self.arrival,
                origin: Self.origin, destination: Self.destination, tripID: Self.tripID.rawValue, trainNumber: "6611"
            )
            return try encoded(JourneySearchStoreFixtures.page(options: [option]))
        case "/v1/journey-plans/resolve":
            guard let data = request.httpBody,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["trackingTokens"] as? [String] == ["token-outbound"] else { throw URLError(.badServerResponse) }
            if !failedResolution {
                failedResolution = true
                throw URLError(.notConnectedToInternet)
            }
            return try json(["directions": [[
                "fingerprint": "paris-lyon-6611-20261114", "originStationId": Self.origin.id.rawValue,
                "destinationStationId": Self.destination.id.rawValue,
                "departure": "2026-11-14T14:00:00Z", "arrival": "2026-11-14T16:00:00Z",
                "segments": [["segmentId": "outbound-rail", "trip": Self.snapshot(refreshed: false), "failure": NSNull()]]
            ]]])
        case "/v1/trips/snapshot":
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            guard value("id") == "eu:transitous:tgv-6611-20261114", value("source") == "transitous",
                  value("nativeId") == "tgv-6611-20261114", value("serviceDate") == "2026-11-14" else {
                throw URLError(.badServerResponse)
            }
            return try json(Self.snapshot(refreshed: true))
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return HTTPResponse(data: try encoder.encode(value), statusCode: 200)
    }

    private func json(_ value: Any) throws -> HTTPResponse {
        HTTPResponse(data: try JSONSerialization.data(withJSONObject: value), statusCode: 200)
    }

    private static func snapshot(refreshed: Bool) -> [String: Any] {
        [
            "id": tripID.rawValue, "source": "transitous", "serviceDate": "2026-11-14",
            "operatorName": "SNCF", "product": "TGV 6611", "headsign": "Lyon Part Dieu",
            "fetchedAt": "2026-11-14T13:00:00Z", "positions": [],
            "stops": [
                ["stationId": origin.id.rawValue, "stationName": origin.displayName, "countryCode": "FR",
                 "latitude": 48.844, "longitude": 2.373, "sequence": 1,
                 "scheduledDeparture": "2026-11-14T14:00:00Z",
                 "expectedDeparture": refreshed ? "2026-11-14T14:05:00Z" : "2026-11-14T14:00:00Z",
                 "plannedPlatform": "7", "expectedPlatform": refreshed ? "9" : "7", "cancelled": false, "passed": false],
                ["stationId": destination.id.rawValue, "stationName": destination.displayName, "countryCode": "FR",
                 "latitude": 45.76, "longitude": 4.86, "sequence": 2,
                 "scheduledArrival": "2026-11-14T16:00:00Z", "expectedArrival": "2026-11-14T16:00:00Z",
                 "plannedPlatform": "3", "expectedPlatform": "3", "cancelled": false, "passed": false]
            ]
        ]
    }
}
