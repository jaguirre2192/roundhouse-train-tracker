import XCTest
import TrainTrackerCore
@testable import TrainTracker

@MainActor
final class WatchingTrainTests: XCTestCase {
    func testWatchingSurvivesColdReloadAndNeverEarnsAStub() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        XCTAssertTrue(try context.library.storeTrackedTrip(trip, watchingOnly: true))
        let cold = TripLibrary(pushCoordinator: RecordingPushCoordinator(), archive: context.archive, automaticRefreshEnabled: false)
        XCTAssertTrue(cold.isWatchingOnly(trip.id))
        let past = trip.serviceDate.addingTimeInterval(7 * 86400)
        let log = TravelLog(seed: [])
        log.recordFinishedRides(in: cold, plans: [], at: past)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.totals.distanceMeters, 0)
        let history = JourneyHistoryArchive(selection: JourneyHistorySelection(plans: [], trips: cold.trips, at: past),
                                            plans: [], watching: cold.watchingOnlyIDs)
        XCTAssertTrue(history.months.isEmpty)
        XCTAssertEqual(history.watched(matching: trip.product).count, 1)
        XCTAssertTrue(cold.removeTrip(id: trip.id))
        XCTAssertTrue(context.archive.loadWatchingIDs().isEmpty)
        XCTAssertTrue(try cold.storeTrackedTrip(trip))
        XCTAssertFalse(cold.isWatchingOnly(trip.id))
    }

    func testConfirmedPartialRideKeepsOnlyChosenStopsAndCanBeRetried() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        try context.library.storeTrackedTrip(trip, watchingOnly: true)
        let section = RiddenTrainSection(trip: trip)
        XCTAssertGreaterThan(section.calls.count, 2)
        let from = section.calls[1], to = try XCTUnwrap(section.calls.last)
        let plan = try XCTUnwrap(section.plan(on: trip, from: from.id, to: to.id, at: trip.serviceDate, knownPlans: []))
        XCTAssertNil(section.plan(on: trip, from: to.id, to: from.id, at: trip.serviceDate, knownPlans: []))
        let store = RecordingJourneyPlanArchive()
        let plans = try JourneyPlanLibrary(tripLibrary: context.library, archive: store)
        store.shouldFailSave = true
        XCTAssertThrowsError(try plans.saveRiddenSection(plan, for: trip.id))
        XCTAssertTrue(context.library.isWatchingOnly(trip.id))
        store.shouldFailSave = false
        try plans.saveRiddenSection(plan, for: trip.id)
        try plans.saveRiddenSection(plan, for: trip.id)
        XCTAssertEqual(plans.plans.count, 1)
        let cold = TripLibrary(pushCoordinator: RecordingPushCoordinator(), archive: context.archive, automaticRefreshEnabled: false)
        XCTAssertFalse(cold.isWatchingOnly(trip.id))
        let log = TravelLog(seed: [])
        log.recordFinishedRides(in: cold, plans: try store.load(), at: trip.serviceDate.addingTimeInterval(7 * 86400))
        let stub = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(stub.originName, from.station.displayName)
        XCTAssertEqual(stub.destinationName, to.station.displayName)
        XCTAssertEqual(stub.stopCount, section.calls.count - 1)
        XCTAssertEqual(log.totals.journeys, 1)
    }

    func testDifferentBookingsOnOneServiceNeverAwardItsWholeRoute() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        try context.library.storeTrackedTrip(trip)
        let section = RiddenTrainSection(trip: trip)
        let first = try XCTUnwrap(section.calls.first), last = try XCTUnwrap(section.calls.last)
        let middle = section.calls[1]
        let firstBooking = try XCTUnwrap(section.plan(on: trip, from: first.id, to: middle.id, at: trip.serviceDate, knownPlans: []))
        let secondBooking = try XCTUnwrap(section.plan(on: trip, from: middle.id, to: last.id, at: trip.serviceDate, knownPlans: []))
        let past = trip.serviceDate.addingTimeInterval(7 * 86400)
        XCTAssertNil(TravelLog.finishedRide(trip, in: context.library, plans: [firstBooking, secondBooking], at: past))
        let stub = try XCTUnwrap(TravelLog.finishedRide(trip, in: context.library, plans: [secondBooking, secondBooking], at: past))
        XCTAssertEqual(stub.originName, middle.station.displayName)
        XCTAssertEqual(stub.destinationName, last.station.displayName)
    }

    func testExistingRideAndLegacyArchivesKeepTheirIntentWhenFollowedAgain() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        try context.archive.saveOrThrow([trip])
        let cold = TripLibrary(pushCoordinator: RecordingPushCoordinator(), archive: context.archive, automaticRefreshEnabled: false)
        XCTAssertFalse(try cold.storeTrackedTrip(trip, watchingOnly: true))
        XCTAssertFalse(cold.isWatchingOnly(trip.id))
        let invalid = JourneyPlanTestFixtures.replacingCoordinate(in: JourneyPlanTestFixtures.makeTrips()[1], latitude: .nan)
        XCTAssertThrowsError(try cold.storeTrackedTrip(invalid, watchingOnly: true))
        XCTAssertTrue(context.archive.loadWatchingIDs().isEmpty)
        XCTAssertEqual(cold.trips.map(\.id), [trip.id])
    }

    func testCorrectingAnOldWatchedStubKeepsTheTrainAndDoesNotRecreateMileage() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        try context.library.storeTrackedTrip(trip)
        let log = TravelLog(seed: [])
        let date = trip.serviceDate.addingTimeInterval(7 * 86400)
        log.recordFinishedRides(in: context.library, plans: [], at: date)
        let stub = try XCTUnwrap(log.entries.first)
        try log.correctWatchedTrain(stub, in: context.library)
        let cold = TripLibrary(pushCoordinator: RecordingPushCoordinator(), archive: context.archive, automaticRefreshEnabled: false)
        log.recordFinishedRides(in: cold, plans: [], at: date)
        XCTAssertTrue(cold.containsTrip(id: trip.id))
        XCTAssertTrue(cold.isWatchingOnly(trip.id))
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(context.push.unwatchedTripIDs.isEmpty)
    }
}
