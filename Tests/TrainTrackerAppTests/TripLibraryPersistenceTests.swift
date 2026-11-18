import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class TripLibraryPersistenceTests: XCTestCase {
    @MainActor
    func testStationBoardTrackingUsesTheSummaryServiceDate() async throws {
        let template = try XCTUnwrap(PreviewTrips.make(
            referenceDate: Date(timeIntervalSince1970: 1_784_574_000)
        ).first)
        let serviceDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z")
        )
        let adapter = ServiceDateRecordingRailAdapter(template: template)
        let push = RecordingPushCoordinator()
        let library = TripLibrary(
            trips: [],
            backendSnapshots: FixtureTripDataProvider(adapter: adapter),
            pushCoordinator: push,
            archive: nil,
            automaticRefreshEnabled: false
        )
        let summary = StopTimeSummary(
            tripID: template.id,
            serviceDate: serviceDate,
            stopTime: try XCTUnwrap(template.stopTimes.first),
            headsign: template.headsign,
            product: template.product
        )

        try await library.addTrip(summary, source: .europe)

        let requestedDates = await adapter.requestedServiceDates()
        XCTAssertEqual(requestedDates, [serviceDate])
        XCTAssertEqual(library.trips.first?.serviceDate, serviceDate)
        XCTAssertEqual(push.watchedTripIDs, [template.id])
    }

    @MainActor
    func testStationBoardTrackingPassesTheServiceDateToTheBackendSnapshot() async throws {
        let template = try XCTUnwrap(PreviewTrips.make(
            referenceDate: Date(timeIntervalSince1970: 1_784_574_000)
        ).last)
        let serviceDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z")
        )
        let http = SnapshotRecordingHTTPClient(json: Self.snapshotJSON)
        let library = TripLibrary(
            trips: [],
            backendSnapshots: TripSnapshotBackendClient(
                baseURL: try XCTUnwrap(URL(string: "https://example.test")),
                client: http
            ),
            pushCoordinator: RecordingPushCoordinator(),
            archive: nil,
            automaticRefreshEnabled: false
        )
        let summary = StopTimeSummary(
            tripID: RailIdentifier(rawValue: "eu:transitous:night-1234"),
            serviceDate: serviceDate,
            stopTime: try XCTUnwrap(template.stopTimes.first),
            headsign: "Amsterdam Centraal",
            product: "Nightjet"
        )

        try await library.addTrip(summary, source: .europe)

        let requests = await http.requests()
        let request = try XCTUnwrap(requests.first)
        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.first(where: { $0.name == "serviceDate" })?.value, "2026-07-23")
        XCTAssertEqual(library.trips.first?.serviceDate, serviceDate)
    }

    @MainActor
    func testTrackedTripInsertionIsIdempotentAndPersistsBeforeWatch() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        var wasPersistedBeforeWatch = false
        context.push.onWatch = { _ in
            wasPersistedBeforeWatch = context.archive.load().contains { $0.id == trip.id }
        }

        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        XCTAssertFalse(try context.library.storeTrackedTrip(trip))

        XCTAssertTrue(wasPersistedBeforeWatch)
        XCTAssertEqual(context.library.trips.map(\.id), [trip.id])
        XCTAssertEqual(context.push.watchedTripIDs, [trip.id])
    }

    @MainActor
    func testTrackedTripPersistenceFailureDoesNotMutateOrQueuePush() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let invalid = JourneyPlanTestFixtures.replacingCoordinate(
            in: JourneyPlanTestFixtures.makeTrips()[0],
            latitude: .nan
        )

        XCTAssertThrowsError(try context.library.storeTrackedTrip(invalid))
        XCTAssertFalse(context.library.containsTrip(id: invalid.id))
        XCTAssertTrue(context.push.watchedTripIDs.isEmpty)
    }

    @MainActor
    func testPushWarningDoesNotRollBackPersistedTripAndCanClear() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]

        XCTAssertTrue(try context.library.storeTrackedTrip(trip))
        context.push.reportDeliveryWarning(true, affectedTripIDs: [trip.id])
        XCTAssertTrue(context.library.pushDeliveryWarning)
        XCTAssertTrue(context.library.containsTrip(id: trip.id))

        context.push.reportDeliveryWarning(false)
        XCTAssertFalse(context.library.pushDeliveryWarning)
        XCTAssertTrue(context.library.containsTrip(id: trip.id))
    }

    @MainActor
    func testCancelledRefreshDoesNotSurfaceAsLiveDataFailure() async throws {
        let trip = try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first { !$0.isComplete })
        let adapter = CancellingRailAdapter(capabilities: trip.capabilities)
        let library = TripLibrary(
            trips: [trip],
            backendSnapshots: FixtureTripDataProvider(adapter: adapter),
            pushCoordinator: RecordingPushCoordinator(),
            archive: nil,
            automaticRefreshEnabled: true,
            now: { trip.serviceDate }
        )

        await library.refreshTrackedTrips()

        XCTAssertNil(library.refreshError)
        XCTAssertNil(library.lastUpdated)
        XCTAssertNil(library.lastSuccessfulCheck(for: trip.id))
        XCTAssertFalse(library.lastRefreshFailed(for: trip.id))
        XCTAssertFalse(library.isRefreshing)
    }

    @MainActor
    func testRetryWithNoTrackedTripsClearsStaleRefreshFailure() async throws {
        let trip = try XCTUnwrap(JourneyPlanTestFixtures.makeTrips().first { !$0.isComplete })
        let adapter = FailingRefreshRailAdapter(capabilities: trip.capabilities)
        let library = TripLibrary(
            trips: [trip],
            backendSnapshots: FixtureTripDataProvider(adapter: adapter),
            pushCoordinator: RecordingPushCoordinator(),
            archive: nil,
            automaticRefreshEnabled: true,
            now: { trip.serviceDate }
        )

        await library.refreshTrackedTrips()
        XCTAssertNotNil(library.refreshError)

        XCTAssertTrue(library.removeTrip(id: trip.id))
        XCTAssertTrue(library.trips.isEmpty)
        XCTAssertNil(
            library.refreshError,
            "Removing the last refreshable trip must immediately clear its stale failure"
        )

        await library.refreshTrackedTrips()

        XCTAssertNil(
            library.refreshError,
            "An empty library has no live trip whose refresh can still be paused"
        )
    }

    @MainActor
    func testTargetedRefreshRequestsOnlyTheSelectedTrackedTrip() async throws {
        let trips = JourneyPlanTestFixtures.makeTrips().filter { !$0.isComplete }
        let selected = try XCTUnwrap(trips.first)
        let adapter = RefreshRecordingRailAdapter(
            trips: trips,
            capabilities: selected.capabilities
        )
        let library = TripLibrary(
            trips: trips,
            backendSnapshots: FixtureTripDataProvider(adapter: adapter),
            pushCoordinator: RecordingPushCoordinator(),
            archive: nil,
            automaticRefreshEnabled: true
        )

        await library.refreshTrackedTrip(id: selected.id)

        let requestedTripIDs = await adapter.requestedTripIDs()
        XCTAssertEqual(requestedTripIDs, [selected.id])
        XCTAssertNil(library.refreshError)
        XCTAssertNotNil(library.lastUpdated)
    }

    private static let snapshotJSON = """
    {
      "id":"eu:transitous:night-1234",
      "source":"transitous",
      "serviceDate":"2026-07-23",
      "operatorName":"European Rail",
      "product":"Nightjet",
      "headsign":"Amsterdam Centraal",
      "fetchedAt":"2026-07-23T00:00:00.000Z",
      "stops":[
        {
          "stationId":"eu:transitous:berlin-hbf","stationName":"Berlin Hbf",
          "countryCode":"DE","latitude":52.525,"longitude":13.369,"sequence":1,
          "scheduledArrival":null,"scheduledDeparture":"2026-07-23T00:12:00.000Z",
          "expectedArrival":null,"expectedDeparture":"2026-07-23T00:14:00.000Z",
          "plannedPlatform":"8","expectedPlatform":"11","cancelled":false,"passed":false
        },
        {
          "stationId":"eu:transitous:amsterdam-centraal","stationName":"Amsterdam Centraal",
          "countryCode":"NL","latitude":52.379,"longitude":4.9,"sequence":2,
          "scheduledArrival":"2026-07-23T06:30:00.000Z","scheduledDeparture":null,
          "expectedArrival":"2026-07-23T06:35:00.000Z","expectedDeparture":null,
          "plannedPlatform":"5","expectedPlatform":"5","cancelled":false,"passed":false
        }
      ]
    }
    """
}

private actor SnapshotRecordingHTTPClient: HTTPClient {
    private let data: Data
    private var recordedRequests: [URLRequest] = []

    init(json: String) {
        data = Data(json.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        return HTTPResponse(data: data, statusCode: 200)
    }

    func requests() -> [URLRequest] { recordedRequests }
}

private actor ServiceDateRecordingRailAdapter: RailAdapter {
    nonisolated let capabilities: RealtimeCapabilities
    private let template: TrainTrip
    private var serviceDates: [Date] = []

    init(template: TrainTrip) {
        capabilities = template.capabilities
        self.template = template
    }

    func searchStations(query: String) async throws -> [Station] { [] }

    func resolveStation(id: RailIdentifier) async throws -> Station {
        guard let station = template.origin else { throw RailAdapterError.notFound }
        return station
    }

    func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection
    ) async throws -> [StopTimeSummary] { [] }

    func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        serviceDates.append(serviceDate)
        return TrainTrip(
            id: id,
            source: template.source,
            serviceDate: serviceDate,
            operatorName: template.operatorName,
            product: template.product,
            headsign: template.headsign,
            stopTimes: template.stopTimes,
            positions: template.positions,
            alerts: template.alerts,
            capabilities: template.capabilities
        )
    }

    func requestedServiceDates() -> [Date] { serviceDates }
}

private actor CancellingRailAdapter: RailAdapter {
    nonisolated let capabilities: RealtimeCapabilities

    init(capabilities: RealtimeCapabilities) {
        self.capabilities = capabilities
    }

    func searchStations(query: String) async throws -> [Station] { [] }
    func resolveStation(id: RailIdentifier) async throws -> Station { throw RailAdapterError.notFound }
    func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection
    ) async throws -> [StopTimeSummary] { [] }
    func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        throw URLError(.cancelled)
    }
}

private actor FailingRefreshRailAdapter: RailAdapter {
    nonisolated let capabilities: RealtimeCapabilities

    init(capabilities: RealtimeCapabilities) {
        self.capabilities = capabilities
    }

    func searchStations(query: String) async throws -> [Station] { [] }
    func resolveStation(id: RailIdentifier) async throws -> Station { throw RailAdapterError.notFound }
    func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection
    ) async throws -> [StopTimeSummary] { [] }

    func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        throw URLError(.notConnectedToInternet)
    }
}

private actor RefreshRecordingRailAdapter: RailAdapter {
    nonisolated let capabilities: RealtimeCapabilities
    private let trips: [RailIdentifier: TrainTrip]
    private var requestedIDs: [RailIdentifier] = []

    init(trips: [TrainTrip], capabilities: RealtimeCapabilities) {
        self.capabilities = capabilities
        self.trips = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
    }

    func searchStations(query: String) async throws -> [Station] { [] }
    func resolveStation(id: RailIdentifier) async throws -> Station { throw RailAdapterError.notFound }
    func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection
    ) async throws -> [StopTimeSummary] { [] }

    func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        requestedIDs.append(id)
        guard let trip = trips[id] else { throw RailAdapterError.notFound }
        return trip
    }

    func requestedTripIDs() -> [RailIdentifier] { requestedIDs }
}
