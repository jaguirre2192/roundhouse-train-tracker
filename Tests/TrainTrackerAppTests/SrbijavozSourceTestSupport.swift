import Foundation
import TrainTrackerCore
@testable import TrainTracker

enum SrbijavozSourceFixture {
    static let baseURL = URL(string: "https://srbijavoz-fixture.invalid")!
    static let now = ISO8601DateFormatter().date(from: "2026-11-14T08:10:00Z")!
    static let fetchedAt = ISO8601DateFormatter().date(from: "2026-11-13T18:00:00Z")!
    static let json = """
    {
      "id":"rs:srbijavoz:fixture-542-20261114","source":"srbijavoz","serviceDate":"2026-11-14",
      "operatorName":"Srbijavoz","product":"Soko 542","headsign":"Petrovaradin",
      "fetchedAt":"2026-11-13T18:00:00Z","positions":[],
      "stops":[
        {"stationId":"rs:srbijavoz:16052","stationName":"Beograd Centar-PROKOP","countryCode":"RS",
         "latitude":44.793,"longitude":20.454,"sequence":1,"scheduledDeparture":"2026-11-14T08:00:00Z",
         "expectedDeparture":null,"plannedPlatform":null,"expectedPlatform":null,"cancelled":false,"passed":false},
        {"stationId":"rs:srbijavoz:16807","stationName":"Petrovaradin","countryCode":"RS",
         "latitude":45.25,"longitude":19.87,"sequence":2,"scheduledArrival":"2026-11-14T08:40:00Z",
         "expectedArrival":null,"plannedPlatform":null,"expectedPlatform":null,"cancelled":false,"passed":false}
      ]
    }
    """

    static func snapshot() throws -> BackendTripSnapshot {
        try JSONDecoder().decode(BackendTripSnapshot.self, from: Data(json.utf8))
    }
}

actor SrbijavozSourceHTTPClient: HTTPClient {
    private let statusCode: Int
    private let data: Data
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int = 200, json: String = SrbijavozSourceFixture.json) {
        self.statusCode = statusCode
        data = Data(json.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(data: data, statusCode: statusCode)
    }
}
