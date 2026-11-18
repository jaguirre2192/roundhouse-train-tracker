import Foundation
import TrainTrackerCore
@testable import TrainTracker

enum BackendOnlyTripDataFixture {
    static let baseURL = URL(string: "https://train-backend.invalid")!
    static let now = ISO8601DateFormatter().date(from: "2026-11-14T10:15:00Z")!
    static let tripID = RailIdentifier(rawValue: "us:transitous:20_us-Amtrak_285229")
    static let stationID = RailIdentifier(rawValue: "us:transitous:WAS")

    static func snapshot(positionAge: TimeInterval? = nil, emptyStops: Bool = false) throws -> Data {
        var value: [String: Any] = [
            "id": tripID.rawValue, "source": "transitous", "serviceDate": "2026-11-14",
            "operatorName": "Amtrak", "product": "2120", "headsign": "New York",
            "fetchedAt": "2026-11-14T10:15:00Z", "stops": emptyStops ? [] : [stop],
        ]
        if let positionAge {
            value["positions"] = [[
                "latitude": 39.176, "longitude": -76.694, "source": "real", "confidence": 1,
                "asOf": ISO8601DateFormatter().string(from: now.addingTimeInterval(-positionAge)),
            ]]
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    static func trip(positionAge: TimeInterval? = nil) throws -> TrainTrip {
        try JSONDecoder().decode(BackendTripSnapshot.self, from: snapshot(positionAge: positionAge)).trip
    }

    static var stop: [String: Any] { [
        "stationId": stationID.rawValue, "stationName": "Washington Union Station", "countryCode": "US",
        "latitude": 38.897, "longitude": -77.006, "sequence": 1,
        "scheduledDeparture": "2026-11-14T10:00:00Z", "expectedDeparture": "2026-11-14T10:05:00Z",
        "plannedPlatform": "2", "expectedPlatform": "3", "platformSource": "Amtraker",
        "cancelled": false, "passed": false,
    ] }

    static func stations() throws -> Data {
        try JSONSerialization.data(withJSONObject: [[
            "id": stationID.rawValue, "nativeId": "WAS", "name": "Washington Union Station",
            "countryCode": "US", "latitude": 38.897, "longitude": -77.006, "operatorHints": ["Amtrak"],
        ]])
    }

    static func board() throws -> Data {
        try JSONSerialization.data(withJSONObject: [[
            "trip": ["id": tripID.rawValue, "serviceDate": "2026-11-14"], "stop": stop,
            "headsign": "New York", "product": "2120",
        ]])
    }
}

actor BackendOnlyTripDataHTTPClient: HTTPClient {
    private var status: Int
    private var snapshot: Data
    private let stations: Data
    private let board: Data
    private(set) var requests: [URLRequest] = []

    init(status: Int = 200, positionAge: TimeInterval? = nil, emptyStops: Bool = false) throws {
        self.status = status
        snapshot = try BackendOnlyTripDataFixture.snapshot(positionAge: positionAge, emptyStops: emptyStops)
        stations = try BackendOnlyTripDataFixture.stations()
        board = try BackendOnlyTripDataFixture.board()
    }

    func setStatus(_ status: Int) { self.status = status }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let data: Data
        switch request.url?.path {
        case "/v1/stations/search": data = stations
        case "/v1/stations/board": data = board
        default: data = snapshot
        }
        return HTTPResponse(data: data, statusCode: status, headerFields: ["Retry-After": "45"])
    }
}
