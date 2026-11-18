import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class TripPositionRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_571_200)

    func testRealPositionKeepsDelayedAmtrakRefreshableAfterTimetableCutoff() {
        let trip = delayedTrip(position: position(asOf: now.addingTimeInterval(-60)))
        XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(trip, at: now))
        XCTAssertEqual(TripAutomaticRefreshPolicy.preferredActiveTrip(in: [trip], at: now)?.id, trip.id)
    }

    func testPositionRecoveryExpiresFromObservationEvenWhenSnapshotWasFetchedAgain() {
        let observedAt = now.addingTimeInterval(-60)
        let cutoff = observedAt.addingTimeInterval(TripAutomaticRefreshPolicy.recoveryWindow)
        let trip = delayedTrip(position: position(asOf: observedAt), fetchedAt: cutoff.addingTimeInterval(1))
        XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(trip, at: cutoff))
        XCTAssertFalse(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(trip, at: cutoff.addingTimeInterval(1)))
    }

    func testInvalidInferredAndStalePositionsCannotReviveOldTrain() {
        let invalid = [
            position(asOf: now, source: .inferred),
            position(asOf: now.addingTimeInterval(-7_201)),
            position(asOf: now.addingTimeInterval(121)),
            position(asOf: Date(timeIntervalSince1970: .nan)),
            position(asOf: now, confidence: 0),
            position(asOf: now, latitude: 91),
            position(asOf: now, latitude: 0, longitude: 0)
        ]
        for observation in invalid {
            XCTAssertFalse(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(
                delayedTrip(position: observation), at: now
            ))
        }
    }

    func testReportedStopObservationGrantsBoundedRecoveryWithoutGPS() {
        let observedAt = now.addingTimeInterval(-60)
        let trip = delayedTrip(position: nil, passageObservedAt: observedAt)
        XCTAssertTrue(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(trip, at: now))
        XCTAssertFalse(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(
            trip, at: observedAt.addingTimeInterval(7_201)
        ))
        XCTAssertFalse(TripAutomaticRefreshPolicy.shouldRefreshAutomatically(
            delayedTrip(position: nil, passageObservedAt: now.addingTimeInterval(121)), at: now
        ))
    }

    @MainActor
    func testAutomaticRefreshAndPushRecoveryContinueAfterOldArrival() async {
        let trip = delayedTrip(position: position(asOf: now.addingTimeInterval(-60)))
        let provider = PositionRecoveryProvider(trip: trip)
        let push = RecordingPushCoordinator()
        let date = now
        let library = TripLibrary(trips: [trip], backendSnapshots: provider, pushCoordinator: push,
                                  archive: nil, now: { date })
        library.resumePushWatches()
        await library.refreshTrackedTrip(id: trip.id, allowEnded: false)
        XCTAssertEqual(push.watchedTripIDs, [trip.id])
        let requests = await provider.requestCount()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(library.lastSuccessfulCheck(for: trip.id), now)
    }

    private func position(asOf: Date, source: PositionSource = .real, confidence: Double = 1,
                          latitude: Double = 39.5, longitude: Double = -76.5) -> VehiclePosition {
        VehiclePosition(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                        source: source, confidence: confidence, asOf: asOf)
    }

    private func delayedTrip(position: VehiclePosition?, fetchedAt: Date? = nil,
                             passageObservedAt: Date? = nil) -> TrainTrip {
        let station = Station(id: RailIdentifier(rawValue: "us:amtraker:WAS"),
                              names: [LocalizedStationName("Washington")],
                              location: GeoCoordinate(latitude: 38.897, longitude: -77.006), countryCode: "US")
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:amtraker:171-13"), source: "amtraker",
            serviceDate: now, operatorName: "Amtrak", product: "171", headsign: "Washington",
            stopTimes: [
                StopTime(station: station, sequence: 1, scheduledDeparture: now.addingTimeInterval(-18_000),
                         isPassed: passageObservedAt != nil, passageObservedAt: passageObservedAt),
                StopTime(station: station, sequence: 2, scheduledArrival: now.addingTimeInterval(-14_400))
            ],
            positions: position.map { [$0] } ?? [], capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: false,
                hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop),
            sourceFetchedAt: fetchedAt ?? now
        )
    }
}

private actor PositionRecoveryProvider: TripDataProviding {
    private let value: TrainTrip
    private var requests = 0
    init(trip: TrainTrip) { value = trip }
    func requestCount() -> Int { requests }
    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip { requests += 1; return value }
    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip { value }
    func searchStations(query: String, source: RailSource) async throws -> [Station] { [] }
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection,
               source: RailSource?) async throws -> [StopTimeSummary] { [] }
}
