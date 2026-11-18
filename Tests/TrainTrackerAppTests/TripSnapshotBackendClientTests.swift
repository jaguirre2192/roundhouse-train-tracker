import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor StubHTTPClient: HTTPClient {
    private let data: Data
    private(set) var request: URLRequest?

    init(json: String) {
        data = Data(json.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        self.request = request
        return HTTPResponse(data: data, statusCode: 200)
    }
}

final class TripSnapshotBackendClientTests: XCTestCase {
    func testBoardPreservesTheAuthoritativeServiceDate() async throws {
        let client = StubHTTPClient(json: Self.overnightBoardJSON)
        let backend = TripSnapshotBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let board = try await backend.board(
            stationID: RailIdentifier(rawValue: "eu:transitous:berlin-hbf"),
            at: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-22T23:55:00Z")),
            direction: .departures
        )

        let departure = try XCTUnwrap(board.first)
        XCTAssertEqual(
            departure.serviceDate,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z"))
        )
        let request = await client.request
        XCTAssertEqual(request?.url?.path, "/v1/stations/board")
        XCTAssertEqual(request?.timeoutInterval, 30)
    }

    func testSharedSnapshotMapperMatchesLegacyTripOutput() async throws {
        let client = StubHTTPClient(json: Self.tripJSON)
        let backend = TripSnapshotBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )
        let serviceDate = Date(timeIntervalSince1970: 1_784_524_800)

        let legacyTrip = try await backend.trip(
            id: RailIdentifier(rawValue: "eu:transitous:be-test-1234"),
            serviceDate: serviceDate
        )
        let snapshot = try JSONDecoder().decode(BackendTripSnapshot.self, from: Data(Self.tripJSON.utf8))

        XCTAssertEqual(snapshot.trip, legacyTrip)
        XCTAssertEqual(legacyTrip.id.rawValue, "eu:transitous:be-test-1234")
        XCTAssertEqual(legacyTrip.stopTimes.first?.expectedPlatform, "6")
        XCTAssertEqual(legacyTrip.stopTimes.first?.isCancelled, false)
        XCTAssertEqual(legacyTrip.positions.first?.source, .real)
        XCTAssertEqual(legacyTrip.routeGeometry?.coordinates.count, 3)
        XCTAssertTrue(legacyTrip.capabilities.hasRealtimeDelays)
        let request = await client.request
        XCTAssertEqual(request?.timeoutInterval, 30)
    }

    func testSnapshotRefreshesPlatformForTheSameStationIdentity() async throws {
        let client = StubHTTPClient(json: Self.tripJSON)
        let backend = TripSnapshotBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )
        let savedJSON = Self.tripJSON
            .replacingOccurrences(of: "\"expectedPlatform\":\"6\"", with: "\"expectedPlatform\":\"4\"")
            .replacingOccurrences(of: "\"stationName\":\"New York Penn\"", with: "\"stationName\":\"Saved New York Penn\"")
        let original = try JSONDecoder().decode(BackendTripSnapshot.self, from: Data(savedJSON.utf8)).trip
        XCTAssertEqual(original.stopTimes.first?.expectedPlatform, "4")

        let value = try await backend.enrichedTrip(original)

        XCTAssertEqual(value.stopTimes.first?.expectedPlatform, "6")
        XCTAssertEqual(value.stopTimes.first?.station, original.stopTimes.first?.station)
        let position = try XCTUnwrap(value.positions.first)
        XCTAssertEqual(position.coordinate.latitude, 3.132123, accuracy: 0.000001)
        XCTAssertEqual(position.coordinate.longitude, 101.68393, accuracy: 0.000001)
        XCTAssertEqual(position.source, .real)
        XCTAssertEqual(position.confidence, 1)
        XCTAssertTrue(value.capabilities.hasPositions)
        let request = await client.request
        XCTAssertEqual(request?.url?.path, "/v1/trips/snapshot")
    }

    func testInternationalSearchMapsCanonicalStation() async throws {
        let client = StubHTTPClient(json: """
        [{
          "id":"eu:transitous:gb-test-waterloo",
          "source":"transitous",
          "nativeId":"gb-test-waterloo",
          "name":"London Waterloo",
          "countryCode":"GB",
          "latitude":51.5033,
          "longitude":-0.1147,
          "operatorHints":[]
        }]
        """)
        let backend = TripSnapshotBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let values = try await backend.searchStations(query: "Waterloo", source: .europe)

        XCTAssertEqual(values.first?.displayName, "London Waterloo")
        XCTAssertEqual(values.first?.countryCode, "GB")
        let request = await client.request
        XCTAssertTrue(request?.url?.query?.contains("scope=international") == true)
        XCTAssertEqual(request?.timeoutInterval, 30)
    }

    func testBoardPreservesSelectedTimeAndCanonicalServiceDate() async throws {
        let client = StubHTTPClient(json: Self.boardJSON)
        let backend = TripSnapshotBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )
        let selectedTime = try XCTUnwrap(WireDate.date(from: "2026-08-15T14:30:00Z"))
        let serviceDate = try XCTUnwrap(WireDate.date(from: "2026-08-15"))

        let values = try await backend.board(
            stationID: RailIdentifier(rawValue: "eu:transitous:de-test-berlin"),
            at: selectedTime,
            direction: .departures
        )

        XCTAssertEqual(values.first?.serviceDate, serviceDate)
        let capturedRequest = await client.request
        let request = try XCTUnwrap(capturedRequest)
        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.first(where: { $0.name == "at" })?.value, "2026-08-15T14:30:00Z")
        XCTAssertEqual(queryItems.first(where: { $0.name == "direction" })?.value, "departures")
    }

    @MainActor
    func testTrackingDepartureUsesItsServiceDateInsteadOfToday() async throws {
        let client = StubHTTPClient(json: Self.tripJSON)
        let backend = TripSnapshotBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )
        let serviceDate = try XCTUnwrap(WireDate.date(from: "2026-08-15"))
        let previewTrip = try XCTUnwrap(PreviewTrips.make(referenceDate: serviceDate).first)
        let summary = StopTimeSummary(
            tripID: RailIdentifier(rawValue: "eu:transitous:be-test-1234"),
            serviceDate: serviceDate,
            stopTime: try XCTUnwrap(previewTrip.stopTimes.first),
            headsign: "Brussels",
            product: "IC 1234"
        )
        let library = TripLibrary(
            trips: [],
            backendSnapshots: backend,
            pushCoordinator: RecordingPushCoordinator(),
            archive: nil,
            automaticRefreshEnabled: false
        )

        try await library.addTrip(summary, source: .europe)

        let capturedRequest = await client.request
        let request = try XCTUnwrap(capturedRequest)
        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.first(where: { $0.name == "serviceDate" })?.value, "2026-08-15")
        XCTAssertEqual(library.trips.first?.id, summary.tripID)
    }

    /// Washington Union, September 15, 2026: a track Amtraker reported earlier and later cleared
    /// must not reappear as an operator timetable value.
    func testAmtrakerClearedTrackIsNotCarriedForwardAsTimetable() throws {
        func snapshot(platform: String?) throws -> BackendTripSnapshot {
            let value = platform.map { "\"\($0)\"" } ?? "null"
            let source = platform == nil ? "null" : "\"Amtraker\""
            return try JSONDecoder().decode(BackendTripSnapshot.self, from: Data("""
            {
              "id":"us:amtraker:2120-15","source":"amtraker","nativeId":"2120-15","serviceDate":"2026-09-15",
              "operatorName":"Amtrak","product":"Acela 2120","headsign":"New York","fetchedAt":"2026-09-15T20:50:00.000Z",
              "alertIds":[],
              "stops":[{"stationId":"us:amtraker:WAS","stationName":"Washington Union","countryCode":"US",
                "latitude":38.897,"longitude":-77.006,"sequence":1,"scheduledArrival":null,
                "scheduledDeparture":"2026-09-15T21:05:00.000Z","expectedArrival":null,
                "expectedDeparture":"2026-09-15T21:05:00.000Z","plannedPlatform":\(value),"expectedPlatform":\(value),
                "platformSource":\(source),"platformObservedAt":null,"cancelled":false,"passed":false}]
            }
            """.utf8))
        }

        let reported = try snapshot(platform: "17").trip
        let reportedStop = try XCTUnwrap(reported.stopTimes.first)
        XCTAssertEqual(reportedStop.platformNoun, "Track")
        XCTAssertEqual(reportedStop.platformSummary(), "Track 17 · via Amtraker")

        let cleared = try snapshot(platform: nil).merging(into: reported)
        let clearedStop = try XCTUnwrap(cleared.stopTimes.first)
        XCTAssertNil(clearedStop.plannedPlatform, "A live-only feed has no timetable value to fall back on")
        XCTAssertNil(clearedStop.expectedPlatform)
        XCTAssertEqual(clearedStop.platformSummary(), "Track not in live feed · Check station boards")
    }

    func testChepeScheduleDoesNotClaimRealtimeCapabilities() throws {
        let snapshot = try JSONDecoder().decode(
            BackendTripSnapshot.self,
            from: Data(Self.chepeJSON.utf8)
        )

        let trip = snapshot.trip

        XCTAssertEqual(trip.source, "chepe")
        XCTAssertFalse(trip.capabilities.hasRealtimeDelays)
        XCTAssertFalse(trip.capabilities.hasPlatforms)
        XCTAssertFalse(trip.capabilities.hasPositions)
        XCTAssertNil(trip.stopTimes.first?.expectedDeparture)
    }

    func testForecastSnapshotMapsSeparateTruthAndPredictionCopy() throws {
        let snapshot = try JSONDecoder().decode(
            BackendTripSnapshot.self,
            from: Data(Self.forecastJSON.utf8)
        )
        let stop = try XCTUnwrap(snapshot.trip.stopTimes.first)
        let forecast = try XCTUnwrap(stop.platformForecast)

        XCTAssertNil(stop.plannedPlatform)
        XCTAssertNil(stop.expectedPlatform)
        XCTAssertEqual(forecast.state, .likelyPlatform)
        XCTAssertEqual(forecast.likelyPlatform, "8")
        XCTAssertEqual(forecast.zone.label, "east concourse")
        let guidance = stop.platformGuidance(at: Date(timeIntervalSince1970: 1_774_120_200))
        XCTAssertEqual(guidance.summaryText, "Likely platform 8 · prediction")
        XCTAssertEqual(guidance.metricValue, "Likely 8")
    }

    func testActiveCardPresentsForecastWithoutCallingItOfficial() throws {
        let snapshot = try JSONDecoder().decode(
            BackendTripSnapshot.self,
            from: Data(Self.forecastJSON.utf8)
        )
        let presentation = ActiveTripCardPresentation(
            trip: snapshot.trip,
            referenceDate: Date(timeIntervalSince1970: 1_774_120_200)
        )

        XCTAssertEqual(presentation.platformText, "Likely platform 8 · prediction")
        XCTAssertEqual(presentation.platformValue, "Likely 8")
    }

    private static let tripJSON = """
    {
      "id":"eu:transitous:be-test-1234",
      "source":"transitous",
      "nativeId":"be-test-1234",
      "serviceDate":"2026-07-21",
      "operatorName":"SNCB",
      "product":"IC 1234",
      "headsign":"Brussels",
      "fetchedAt":"2026-07-21T19:00:00.000Z",
      "alertIds":[],
      "routeGeometry":{
        "source":"Transitous/MOTIS",
        "segments":[{
          "encodedPolyline":"_p~iF~ps|U_ulLnnqC_mqNvxq`@",
          "precision":5,
          "pointCount":3
        }]
      },
      "positions":[{
        "latitude":3.132123,
        "longitude":101.68393,
        "heading":185,
        "source":"real",
        "confidence":1,
        "asOf":"2026-07-21T19:00:00.000Z",
        "provider":"Malaysia Open API KTMB GTFS-RT"
      }],
      "stops":[{
        "stationId":"us:amtraker:NYP",
        "stationName":"New York Penn",
        "countryCode":"BE",
        "latitude":50.8357,
        "longitude":4.3365,
        "sequence":1,
        "scheduledArrival":null,
        "scheduledDeparture":"2026-07-21T19:20:00.000Z",
        "expectedArrival":null,
        "expectedDeparture":"2026-07-21T19:25:00.000Z",
        "plannedPlatform":"4",
        "expectedPlatform":"6",
        "platformSource":"iRail",
        "platformObservedAt":"2026-07-21T19:19:40.000Z",
        "cancelled":false,
        "passed":false
      }]
    }
    """

    private static let boardJSON = """
    [{
      "trip":{"id":"eu:transitous:de-test-ice-742","serviceDate":"2026-08-15"},
      "headsign":"Münster Hbf",
      "product":"ICE 742",
      "stop":{
        "stationId":"eu:transitous:de-test-berlin",
        "stationName":"Berlin Hbf",
        "countryCode":"DE",
        "latitude":52.525,
        "longitude":13.369,
        "sequence":1,
        "scheduledArrival":null,
        "scheduledDeparture":"2026-08-15T14:42:00.000Z",
        "expectedArrival":null,
        "expectedDeparture":"2026-08-15T14:45:00.000Z",
        "plannedPlatform":"7",
        "expectedPlatform":"8",
        "cancelled":false,
        "passed":false
      }
    }]
    """

    private static let overnightBoardJSON = """
    [{
      "trip":{"id":"eu:transitous:night-1234","serviceDate":"2026-07-23"},
      "headsign":"Amsterdam Centraal",
      "product":"Nightjet",
      "stop":{
        "stationId":"eu:transitous:berlin-hbf",
        "stationName":"Berlin Hbf",
        "countryCode":"DE",
        "latitude":52.525,
        "longitude":13.369,
        "sequence":4,
        "scheduledArrival":"2026-07-23T00:08:00.000Z",
        "scheduledDeparture":"2026-07-23T00:12:00.000Z",
        "expectedArrival":"2026-07-23T00:10:00.000Z",
        "expectedDeparture":"2026-07-23T00:14:00.000Z",
        "plannedPlatform":"8",
        "expectedPlatform":"11",
        "cancelled":false,
        "passed":false
      }
    }]
    """

    private static let chepeJSON = """
    {
      "id":"mx:chepe:express-los-mochis-creel:2026-07-23",
      "source":"chepe",
      "nativeId":"express-los-mochis-creel:2026-07-23",
      "serviceDate":"2026-07-23",
      "operatorName":"Ferromex / Chepe Express",
      "product":"Chepe Express",
      "headsign":"Creel",
      "fetchedAt":"2026-07-22T18:00:00.000Z",
      "alertIds":[],
      "stops":[{
        "stationId":"mx:chepe:los-mochis",
        "stationName":"Los Mochis",
        "countryCode":"MX",
        "latitude":25.7611676,
        "longitude":-108.9672524,
        "sequence":1,
        "scheduledArrival":null,
        "scheduledDeparture":"2026-07-23T17:11:00.000Z",
        "expectedArrival":null,
        "expectedDeparture":null,
        "plannedPlatform":null,
        "expectedPlatform":null,
        "platformSource":null,
        "platformObservedAt":null,
        "cancelled":false,
        "passed":false
      }]
    }
    """

    private static let forecastJSON = """
    {
      "id":"eu:transitous:ice-742",
      "source":"transitous",
      "nativeId":"ice-742",
      "serviceDate":"2026-03-21",
      "operatorName":"DB Fernverkehr AG",
      "product":"ICE 742",
      "headsign":"Münster Hbf",
      "fetchedAt":"2026-03-21T19:00:00.000Z",
      "alertIds":[],
      "stops":[{
        "stationId":"eu:transitous:berlin-hbf",
        "stationName":"Berlin Hbf",
        "countryCode":"DE",
        "latitude":52.525,
        "longitude":13.369,
        "sequence":1,
        "scheduledArrival":null,
        "scheduledDeparture":"2026-03-21T20:00:00.000Z",
        "expectedArrival":null,
        "expectedDeparture":null,
        "plannedPlatform":null,
        "expectedPlatform":null,
        "platformSource":null,
        "platformObservedAt":null,
        "cancelled":false,
        "passed":false,
        "platformForecast":{
          "kind":"forecast",
          "state":"likely-platform",
          "zone":{"id":"east","label":"east concourse","platforms":["8","9"],"probability":0.93},
          "candidates":[
            {"platform":"8","probability":0.87,"observationCount":27},
            {"platform":"9","probability":0.13,"observationCount":3}
          ],
          "likelyPlatform":"8",
          "confidence":"high",
          "evidenceCount":30,
          "explanation":"30 completed comparable services in 2025-2026.",
          "horizon":"1h-to-6h",
          "modelVersion":"historical-bayes-v1",
          "timetablePeriod":"2025-2026",
          "stationMapVersion":"berlin-map-v1",
          "generatedAt":"2026-03-21T19:00:00.000Z",
          "expiresAt":"2026-03-21T19:30:00.000Z"
        }
      }]
    }
    """
}
