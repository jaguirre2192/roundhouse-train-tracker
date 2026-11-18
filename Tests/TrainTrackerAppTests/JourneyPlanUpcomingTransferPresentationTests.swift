import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class JourneyPlanUpcomingTransferPresentationTests: XCTestCase {
    private let fixture = JourneyExperiencePreviewData.make(.connection)
    private var legs: [JourneyPlanSegment] { fixture.plan.outbound.selectedSegments! }

    func testHealthyFutureSelectedLegShowsItsStationServiceAndTimetableDeparture() throws {
        let value = try XCTUnwrap(present())
        XCTAssertEqual(value.next.id, legs[1].id)
        XCTAssertEqual(value.stationName, "New York Penn Station")
        XCTAssertEqual(value.serviceName, "Northeast Regional 174")
        XCTAssertEqual(value.next.departure, legs[1].departure)
        XCTAssertTrue(value.walks.isEmpty)
        XCTAssertTrue(value.departureText?.hasPrefix("Timetable departure ") == true)
    }

    func testOnwardEstimateCannotReplaceTheExplicitSavedDeparture() throws {
        let saved = try XCTUnwrap(legs[1].departure)
        let delayed = replacing(fixture.trips[1], station: legs[1].from.id, expectedDeparture: saved.addingTimeInterval(1800))
        let value = try XCTUnwrap(present(trips: [fixture.trips[0], delayed]))
        XCTAssertEqual(value.next.departure, saved)
        XCTAssertNotEqual(value.next.departure, delayed.stopTimes.first?.expectedDeparture)
        XCTAssertTrue(value.departureText?.contains(JourneyPlanDateTimePresentation.labeledTime(
            saved, timeZoneIdentifier: legs[1].from.timeZoneIdentifier
        )) == true)
    }

    func testMissingSavedDepartureDoesNotBorrowATimeFromTheTrainSnapshot() throws {
        let original = legs[1]
        let untimed = JourneyPlanSegment(id: original.id, kind: .rail,
            from: original.from, to: original.to, arrival: original.arrival,
            serviceName: original.serviceName, resolvedTripID: original.resolvedTripID)
        let value = try XCTUnwrap(present(plan: plan(segments: [legs[0], untimed])))
        XCTAssertNil(value.next.departure)
        XCTAssertNil(value.departureText)
    }

    func testActiveTransferDoesNotDuplicateExistingConnectionGuidance() {
        let stage = makeStage(at: 190)
        XCTAssertEqual(stage.kind, .connection)
        XCTAssertNil(JourneyPlanUpcomingTransferPresentation(stage: stage, trips: fixture.trips, referenceDate: date(190)))
    }

    func testTightAndMissedRisksRemainOwnedByExistingGuidance() {
        for arrivalMinute in [202.0, 220.0] {
            let late = replacing(fixture.trips[0], station: legs[0].to.id, expectedArrival: date(arrivalMinute))
            let trips = [late, fixture.trips[1]]
            let stage = makeStage(trips: trips)
            XCTAssertEqual(stage.kind, .rail)
            XCTAssertNotNil(stage.connection)
            XCTAssertNil(present(trips: trips))
        }
    }

    func testElapsedSavedDepartureHidesEvenWhenTheIncomingTrainIsStillRunning() {
        let late = replacing(fixture.trips[0], station: legs[0].to.id, expectedArrival: date(240))
        let stage = makeStage(trips: [late], at: 210)
        XCTAssertEqual(stage.kind, .rail)
        XCTAssertNil(stage.connection)
        XCTAssertNil(present(trips: [late], at: 210))
    }

    func testCancelledPassengerEndpointsHideWithoutRequiringWholeTrainCancellation() {
        let incoming = replacing(fixture.trips[0], station: legs[0].to.id, cancelled: true)
        let onward = replacing(fixture.trips[1], station: legs[1].from.id, cancelled: true)
        XCTAssertFalse(incoming.isCancelled)
        XCTAssertFalse(onward.isCancelled)
        XCTAssertNil(present(trips: [incoming, fixture.trips[1]]))
        XCTAssertNil(present(trips: [fixture.trips[0], onward]))
    }

    func testDisconnectedSelectedStationsDoNotInventAChange() {
        let next = copied(legs[1], from: legs[0].from)
        XCTAssertNil(present(plan: plan(segments: [legs[0], next])))
    }

    func testExplicitContinuousWalkRemainsPartOfTheSavedNextStep() throws {
        let walk = JourneyPlanSegment(id: "planned-platform-walk", kind: .walk,
            from: legs[0].to, to: legs[1].from, duration: 300)
        let value = try XCTUnwrap(present(plan: plan(segments: [legs[0], walk, legs[1]])))
        XCTAssertEqual(value.next, legs[1])
        XCTAssertEqual(value.walks, [walk])
        let broken = JourneyPlanSegment(id: "broken-walk", kind: .walk,
            from: legs[0].from, to: legs[1].from, duration: 300)
        XCTAssertNil(present(plan: plan(segments: [legs[0], broken, legs[1]])))
    }

    func testDirectAndLegacyPlansDoNotInferAnUpcomingTransfer() {
        XCTAssertNil(present(plan: plan(segments: [legs[0]])))
        XCTAssertNil(present(at: 460))
        let legacy = plan(segments: nil)
        XCTAssertEqual(makeStage(plan: legacy).kind, .legacy)
        XCTAssertNil(present(plan: legacy))
    }

    func testDuplicateFutureLegIdentityDoesNotInventAChange() {
        let walk = JourneyPlanSegment(id: "duplicate-walk", kind: .walk,
            from: legs[0].to, to: legs[1].from, duration: 60)
        let duplicated = plan(segments: [legs[0], walk, walk, legs[1]])
        XCTAssertEqual(makeStage(plan: duplicated).kind, .rail)
        XCTAssertNil(present(plan: duplicated))
    }

    func testMissingOnwardSnapshotKeepsExplicitSavedNextStepAvailable() throws {
        let value = try XCTUnwrap(present(trips: [fixture.trips[0]]))
        XCTAssertEqual(value.next, legs[1])
        XCTAssertEqual(value.next.departure, legs[1].departure)
    }

    func testAmbiguousOnwardSnapshotIsNotPresentedAsAHealthyNextStep() {
        XCTAssertNil(present(trips: fixture.trips + [fixture.trips[1]]))
    }

    private func date(_ minutes: TimeInterval) -> Date {
        fixture.plan.outbound.departure.addingTimeInterval(minutes * 60)
    }

    private func makeStage(plan: TrackedJourneyPlan? = nil, trips: [TrainTrip]? = nil, at minute: TimeInterval = 120) -> JourneyPlanStage {
        JourneyPlanStage(plan: plan ?? fixture.plan, trips: trips ?? fixture.trips, referenceDate: date(minute))
    }

    private func present(plan: TrackedJourneyPlan? = nil, trips: [TrainTrip]? = nil, at minute: TimeInterval = 120) -> JourneyPlanUpcomingTransferPresentation? {
        JourneyPlanUpcomingTransferPresentation(
            stage: makeStage(plan: plan, trips: trips, at: minute),
            trips: trips ?? fixture.trips, referenceDate: date(minute)
        )
    }

    private func plan(segments: [JourneyPlanSegment]?) -> TrackedJourneyPlan {
        let base = fixture.plan
        return TrackedJourneyPlan(id: base.id, createdAt: base.createdAt,
            origin: segments?.first?.from ?? base.origin,
            destination: segments?.last?.to ?? base.destination,
            outbound: JourneyPlanDirection(fingerprint: "upcoming-transfer-test",
                departure: segments?.first?.departure ?? base.outbound.departure,
                arrival: segments?.last?.arrival ?? base.outbound.arrival,
                childTripIDs: segments?.compactMap(\.resolvedTripID) ?? base.outbound.childTripIDs,
                selectedSegments: segments), returnDirection: nil, preExistingChildTripIDs: [])
    }

    private func copied(_ segment: JourneyPlanSegment, from: RailPlace) -> JourneyPlanSegment {
        JourneyPlanSegment(id: segment.id, kind: segment.kind, from: from, to: segment.to,
            departure: segment.departure, arrival: segment.arrival, serviceName: segment.serviceName,
            resolvedTripID: segment.resolvedTripID, unavailableReason: segment.unavailableReason,
            duration: segment.duration, isStationChange: segment.isStationChange)
    }

    private func replacing(_ trip: TrainTrip, station: RailIdentifier,
                           expectedArrival: Date? = nil, expectedDeparture: Date? = nil,
                           cancelled: Bool = false) -> TrainTrip {
        TrainTrip(id: trip.id, source: trip.source, serviceDate: trip.serviceDate,
            operatorName: trip.operatorName, product: trip.product, headsign: trip.headsign,
            stopTimes: trip.stopTimes.map { stop in
                guard stop.station.id == station else { return stop }
                return StopTime(station: stop.station, sequence: stop.sequence,
                    scheduledArrival: stop.scheduledArrival, scheduledDeparture: stop.scheduledDeparture,
                    expectedArrival: expectedArrival ?? stop.expectedArrival,
                    expectedDeparture: expectedDeparture ?? stop.expectedDeparture,
                    plannedPlatform: stop.plannedPlatform, expectedPlatform: stop.expectedPlatform,
                    platformKind: stop.platformKind, isCancelled: cancelled || stop.isCancelled)
            }, capabilities: trip.capabilities)
    }
}
