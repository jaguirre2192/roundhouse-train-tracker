import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyPlanStageTests: XCTestCase {
    private let originDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testDirectJourneyRetainsItsSelectedLegBeforeAndAfterTravel() {
        let selected = rail("out", from: "A", to: "B", departure: 0, arrival: 60)
        let trip = train("out", stops: [
            stop("Before", sequence: 1, departure: -30),
            stop("A", sequence: 2, departure: 0),
            stop("B", sequence: 3, arrival: 60),
            stop("Beyond", sequence: 4, arrival: 120),
        ])
        for minute in [-60.0, 20.0, 90.0] {
            let stage = JourneyPlanStage(plan: plan([selected]), trips: [trip], referenceDate: date(minute))
            XCTAssertEqual(stage.kind, .rail)
            XCTAssertEqual(stage.directionTitle, "Outbound")
            XCTAssertEqual(stage.focusSegment, selected)
            XCTAssertEqual(stage.focusTrip?.id, trip.id)
            XCTAssertNil(stage.connection)
        }
    }

    func testReturnSelectionUsesScopedEstimatedArrivalInsteadOfWholeTrainOrSavedEnd() {
        let outgoing = rail("out", from: "A", to: "B", departure: 0, arrival: 60)
        let returning = rail("back", from: "B", to: "A", departure: 240, arrival: 300)
        let outboundTrip = train("out", stops: [
            stop("Before", sequence: 1, departure: -30),
            stop("A", sequence: 2, departure: 0),
            stop("B", sequence: 3, arrival: 60, expectedArrival: 90),
            stop("Beyond", sequence: 4, arrival: 120),
        ])
        let trips = [outboundTrip, train(for: returning)]
        let saved = plan([outgoing], returnSegments: [returning])
        let delayedOutbound = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(70))
        let returnStage = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(90))
        XCTAssertEqual(delayedOutbound.directionTitle, "Outbound")
        XCTAssertEqual(delayedOutbound.focusSegment?.id, "out")
        XCTAssertEqual(returnStage.directionTitle, "Return")
        XCTAssertEqual(returnStage.focusSegment?.id, "back")
        XCTAssertEqual(returnStage.direction, saved.returnDirection)
    }

    func testCancelledOrMissingOutboundDoesNotImmediatelySelectReturn() {
        let outgoing = rail("out", from: "A", to: "B", departure: 0, arrival: 60)
        let returning = rail("back", from: "B", to: "A", departure: 240, arrival: 300)
        let cancelled = train("out", stops: [
            stop("A", sequence: 1, departure: 0, cancelled: true, passed: true),
            stop("B", sequence: 2, arrival: 60, expectedArrival: 1, cancelled: true, passed: true),
        ])
        let cancelledArrival = train("out", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 60, expectedArrival: 1, cancelled: true),
        ])
        let saved = plan([outgoing], returnSegments: [returning])
        for trips in [[train(for: returning)], [cancelled, train(for: returning)], [cancelledArrival, train(for: returning)]] {
            let beforeEnd = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(10))
            let afterEnd = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(60))
            XCTAssertEqual(beforeEnd.directionTitle, "Outbound")
            XCTAssertEqual(beforeEnd.focusSegment?.id, "out")
            XCTAssertNil(beforeEnd.connection)
            XCTAssertEqual(afterEnd.directionTitle, "Return")
        }
    }

    func testSameStationConnectionAppearsOnlyBetweenRailTimes() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 50, arrival: 90)
        let trips = [train(for: first), train(for: next)]
        let saved = plan([first, next])
        let beforeArrival = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(29))
        let atArrival = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(30))
        let atDeparture = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(50))
        XCTAssertEqual(beforeArrival.kind, .rail)
        XCTAssertEqual(beforeArrival.focusSegment, first)
        XCTAssertEqual(atArrival.kind, .connection)
        XCTAssertEqual(atArrival.focusSegment, next)
        XCTAssertEqual(atArrival.focusTrip?.id, next.resolvedTripID)
        XCTAssertEqual(atArrival.connection?.previous, first)
        XCTAssertEqual(atArrival.connection?.next, next)
        XCTAssertEqual(atArrival.connection?.walks, [])
        XCTAssertEqual(atArrival.connection?.timetableMinutes, 20)
        XCTAssertNil(atArrival.connection?.estimatedMinutes)
        XCTAssertEqual(atDeparture.kind, .rail)
        XCTAssertEqual(atDeparture.focusSegment, next)
        XCTAssertNil(atDeparture.connection)
    }

    func testExplicitStationChangeWalksEstablishConnectionAndRemainInOrder() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let walks = [walk("walk-1", from: "B", to: "Middle"), walk("walk-2", from: "Middle", to: "C")]
        let next = rail("next", from: "C", to: "D", departure: 60, arrival: 90)
        let saved = plan([first] + walks + [next])
        let trips = [train(for: first), train(for: next)]
        let transfer = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(45))
        let onward = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(60))
        XCTAssertEqual(transfer.kind, .connection)
        XCTAssertEqual(transfer.connection?.walks, walks)
        XCTAssertEqual(transfer.connection?.timetableMinutes, 30)
        XCTAssertEqual(transfer.focusSegment, next)
        XCTAssertEqual(onward.kind, .rail)
        XCTAssertEqual(onward.focusSegment, next)
    }

    func testDifferentStationsWithoutContinuousWalkingMetadataAreNotAConnection() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "C", to: "D", departure: 60, arrival: 90)
        let trips = [train(for: first), train(for: next)]
        let absent = JourneyPlanStage(plan: plan([first, next]), trips: trips, referenceDate: date(45))
        let broken = JourneyPlanStage(
            plan: plan([first, walk("broken", from: "B", to: "Wrong"), next]),
            trips: trips, referenceDate: date(45)
        )
        XCTAssertNil(absent.connection)
        XCTAssertEqual(absent.kind, .rail)
        XCTAssertNil(broken.connection)
        XCTAssertEqual(broken.kind, .walk)
        XCTAssertNil(broken.focusTrip)
    }

    func testUnsupportedMiddleRailRemainsVisibleAndBlocksInventedAdjacency() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let unsupported = rail("unsupported", from: "B", to: "C", departure: 35, arrival: 50, tracked: false)
        let last = rail("last", from: "C", to: "D", departure: 60, arrival: 90)
        let saved = plan([first, unsupported, last])
        let trips = [train(for: first), train(for: last)]
        let middle = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(40))
        let later = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(55))
        XCTAssertEqual(middle.kind, .untracked)
        XCTAssertEqual(middle.focusSegment, unsupported)
        XCTAssertNil(middle.focusTrip)
        XCTAssertNil(middle.connection)
        XCTAssertEqual(later.focusSegment, last)
        XCTAssertNil(later.connection)
    }

    func testRepeatedTripBindingOrDuplicateSnapshotIdentityIsUntracked() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30, tripID: id("shared"))
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90, tripID: id("shared"))
        let shared = train("shared", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, departure: 60),
            stop("C", sequence: 3, arrival: 90),
        ])
        let repeated = JourneyPlanStage(plan: plan([first, next]), trips: [shared], referenceDate: date(10))
        let duplicates = JourneyPlanStage(plan: plan([first]), trips: [shared, shared], referenceDate: date(10))
        for stage in [repeated, duplicates] {
            XCTAssertEqual(stage.kind, .untracked)
            XCTAssertNil(stage.focusTrip)
            XCTAssertNil(stage.connection)
        }
    }

    func testDuplicateSelectedSegmentIDsDoNotBindToEitherTrain() {
        let first = rail("duplicate", from: "A", to: "B", departure: 0, arrival: 30, tripID: id("first"))
        let next = rail("duplicate", from: "B", to: "C", departure: 60, arrival: 90, tripID: id("next"))
        let stage = JourneyPlanStage(
            plan: plan([first, next]), trips: [train(for: first), train(for: next)], referenceDate: date(10)
        )
        XCTAssertEqual(stage.kind, .untracked)
        XCTAssertNil(stage.focusTrip)
    }

    func testInvalidSelectedStationsDoNotExposeFullTrainAsPassengerContext() {
        let selected = rail("selected", from: "Wrong", to: "Missing", departure: 0, arrival: 60)
        let trip = train("selected", stops: [
            stop("A", sequence: 1, departure: 0), stop("B", sequence: 2, arrival: 60),
        ])
        let stage = JourneyPlanStage(plan: plan([selected]), trips: [trip], referenceDate: date(10))
        XCTAssertEqual(stage.kind, .untracked)
        XCTAssertEqual(stage.focusSegment, selected)
        XCTAssertNil(stage.focusTrip)
        XCTAssertNil(stage.connection)
    }

    func testLegacyPlanDoesNotGuessSelectedStopsFromChildren() {
        let direction = JourneyPlanDirection(
            fingerprint: "legacy", departure: date(0), arrival: date(60), childTripIDs: [id("legacy")]
        )
        let saved = makePlan(outbound: direction, returnDirection: nil)
        let trip = train("legacy", stops: [
            stop("A", sequence: 1, departure: 0), stop("B", sequence: 2, arrival: 60),
        ])
        let stage = JourneyPlanStage(plan: saved, trips: [trip], referenceDate: date(10))
        XCTAssertEqual(stage.kind, .legacy)
        XCTAssertNil(stage.focusSegment)
        XCTAssertNil(stage.focusTrip)
        XCTAssertNil(stage.connection)
    }

    func testLateEstimatedArrivalReducesConnectionIntervalWithoutChangingTimetable() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let late = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 50),
        ])
        let trips = [late, train(for: next)]
        let saved = plan([first, next])
        let stillTravelling = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(40))
        let transfer = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(55))
        XCTAssertEqual(stillTravelling.kind, .rail)
        XCTAssertEqual(stillTravelling.focusSegment, first)
        XCTAssertNil(stillTravelling.connection)
        XCTAssertEqual(transfer.kind, .connection)
        XCTAssertEqual(transfer.connection?.timetableMinutes, 30)
        XCTAssertEqual(transfer.connection?.estimatedMinutes, 10)
    }

    func testCancelledConnectingCallDoesNotOfferAConnection() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let cancelledCall = train("first", stops: [
            stop("A", sequence: 1, departure: 0), stop("B", sequence: 2, arrival: 30, cancelled: true),
        ])
        let stage = JourneyPlanStage(
            plan: plan([first, next]), trips: [cancelledCall, train(for: next)], referenceDate: date(45)
        )
        XCTAssertNil(stage.connection)
        XCTAssertEqual(stage.kind, .rail)
    }

    func testStandaloneWalkAndUntimedUnsupportedLegRemainExplicit() {
        let walking = walk("walking", from: "A", to: "B")
        let unsupported = JourneyPlanSegment(
            id: "unknown", kind: .rail, from: place("A"), to: place("B"), unavailableReason: "Unavailable"
        )
        let walkStage = JourneyPlanStage(plan: plan([walking]), trips: [], referenceDate: date(10))
        let unknownStage = JourneyPlanStage(plan: plan([unsupported]), trips: [], referenceDate: date(10))
        XCTAssertEqual(walkStage.kind, .walk)
        XCTAssertEqual(walkStage.focusSegment, walking)
        XCTAssertNil(walkStage.focusTrip)
        XCTAssertEqual(unknownStage.kind, .untracked)
        XCTAssertEqual(unknownStage.focusSegment, unsupported)
    }

    func testMissedConnectionAdvisoryAppearsBeforeArrivalAndPersistsAfterBothEvents() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let late = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 70),
        ])
        let saved = plan([first, next])
        for minute in [-15.0, 30.0, 60.0, 69.0, 70.0, 95.0] {
            let stage = JourneyPlanStage(plan: saved, trips: [late, train(for: next)], referenceDate: date(minute))
            XCTAssertEqual(stage.kind, .rail)
            XCTAssertEqual(stage.focusSegment, minute < 70 ? first : next)
            XCTAssertEqual(stage.focusTrip?.id, minute < 70 ? first.resolvedTripID : next.resolvedTripID)
            XCTAssertEqual(stage.connection?.previous, first)
            XCTAssertEqual(stage.connection?.next, next)
            XCTAssertEqual(stage.connection?.timetableMinutes, 30)
            XCTAssertEqual(stage.connection?.estimatedMinutes, -10)
        }
    }

    func testZeroEstimatedConnectionIntervalIsAnAdvisoryNotATransferWindow() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let late = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 60),
        ])
        let stage = JourneyPlanStage(plan: plan([first, next]), trips: [late, train(for: next)], referenceDate: date(10))
        XCTAssertEqual(stage.kind, .rail)
        XCTAssertEqual(stage.focusSegment, first)
        XCTAssertEqual(stage.connection?.estimatedMinutes, 0)
    }

    func testRiskScanCannotBridgeAnUnsupportedMiddleRail() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let middle = rail("middle", from: "B", to: "C", departure: 40, arrival: 60, tracked: false)
        let last = rail("last", from: "C", to: "D", departure: 70, arrival: 90)
        let late = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 100),
        ])
        let stage = JourneyPlanStage(
            plan: plan([first, middle, last]), trips: [late, train(for: last)], referenceDate: date(10)
        )
        XCTAssertEqual(stage.focusSegment, first)
        XCTAssertNil(stage.connection)
    }

    func testDelayedEarlierOutboundLegHoldsDirectionUntilItsScopedEnd() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let last = rail("last", from: "B", to: "C", departure: 60, arrival: 90)
        let returning = rail("back", from: "C", to: "A", departure: 240, arrival: 300)
        let late = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 120),
        ])
        let saved = plan([first, last], returnSegments: [returning])
        let trips = [late, train(for: last), train(for: returning)]
        for minute in [90.0, 119.0] {
            let stage = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(minute))
            XCTAssertEqual(stage.directionTitle, "Outbound")
            XCTAssertEqual(stage.focusSegment, first)
            XCTAssertEqual(stage.connection?.estimatedMinutes, -60)
        }
        let afterEnd = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(120))
        XCTAssertEqual(afterEnd.directionTitle, "Return")
        XCTAssertEqual(afterEnd.focusSegment, returning)
        XCTAssertNil(afterEnd.connection)

        let cancelled = train("first", stops: [
            stop("A", sequence: 1, departure: 0, cancelled: true),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 120, cancelled: true),
        ])
        let cancelledStage = JourneyPlanStage(
            plan: saved, trips: [cancelled, train(for: last), train(for: returning)], referenceDate: date(90)
        )
        XCTAssertEqual(cancelledStage.directionTitle, "Return")
        XCTAssertNil(cancelledStage.connection)
    }

    func testDelayThatSqueezesAChangeIsATightConnectionUntilTheOnwardTrainLeaves() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let late = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 57),
        ])
        let saved = plan([first, next])
        let trips = [late, train(for: next)]
        let travelling = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(10))
        XCTAssertEqual(travelling.kind, .rail)
        XCTAssertEqual(travelling.focusSegment, first)
        XCTAssertEqual(travelling.connection?.estimatedMinutes, 3)
        XCTAssertEqual(travelling.connection?.isTight, true)
        XCTAssertEqual(travelling.connection?.isMissed, false)

        let changing = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(58))
        XCTAssertEqual(changing.kind, .connection)
        XCTAssertEqual(changing.connection?.isTight, true)

        let gone = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(61))
        XCTAssertNil(gone.connection)
    }

    func testTightConnectionAccountsForTheSavedWalkAndIgnoresAnUnchangedTimetable() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let change = walk("walk", from: "B", to: "C")
        let next = rail("next", from: "C", to: "D", departure: 45, arrival: 90)
        let slightlyLate = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 36),
        ])
        let stage = JourneyPlanStage(plan: plan([first, change, next]), trips: [slightlyLate, train(for: next)],
                                     referenceDate: date(10))
        XCTAssertEqual(stage.connection?.walkMinutes, 10)
        XCTAssertEqual(stage.connection?.estimatedMinutes, 9)
        XCTAssertEqual(stage.connection?.isTight, true)
        XCTAssertTrue(JourneyHomeGuidance.connectionRiskMessage(stage.connection!).contains("leaves 9 min"))
        XCTAssertTrue(JourneyHomeGuidance.connectionRiskMessage(stage.connection!).contains("10 min walk"))

        let onTime = JourneyPlanStage(plan: plan([first, change, next]), trips: [train(for: first), train(for: next)],
                                      referenceDate: date(10))
        XCTAssertNil(onTime.connection)
    }

    func testRiskClearsWhenRevisedEstimatesRestoreATransferWindow() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let revised = train("first", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 30, expectedArrival: 50),
        ])
        let stage = JourneyPlanStage(
            plan: plan([first, next]), trips: [revised, train(for: next)], referenceDate: date(55)
        )
        XCTAssertEqual(stage.kind, .connection)
        XCTAssertEqual(stage.focusSegment, next)
        XCTAssertEqual(stage.connection?.estimatedMinutes, 10)
    }

    private func date(_ minutes: Double) -> Date { originDate.addingTimeInterval(minutes * 60) }
    private func id(_ name: String) -> RailIdentifier { RailIdentifier(rawValue: "eu:test:\(name)") }

    private func place(_ name: String) -> RailPlace {
        RailPlace(
            id: id(name), kind: .station, displayName: name, context: "", countryCode: "GB",
            timeZoneIdentifier: "Europe/London", location: GeoCoordinate(latitude: 0, longitude: 0),
            eligibleModes: ["regionalRail"], attributions: []
        )
    }

    private func rail(
        _ name: String, from: String, to: String, departure: Double, arrival: Double,
        tracked: Bool = true, tripID: RailIdentifier? = nil
    ) -> JourneyPlanSegment {
        JourneyPlanSegment(
            id: name, kind: .rail, from: place(from), to: place(to),
            departure: date(departure), arrival: date(arrival), serviceName: name,
            resolvedTripID: tracked ? (tripID ?? id(name)) : nil,
            unavailableReason: tracked ? nil : "This train cannot be tracked"
        )
    }

    private func walk(_ name: String, from: String, to: String) -> JourneyPlanSegment {
        JourneyPlanSegment(
            id: name, kind: .walk, from: place(from), to: place(to), duration: 600, isStationChange: from != to
        )
    }

    private func plan(
        _ segments: [JourneyPlanSegment], returnSegments: [JourneyPlanSegment]? = nil
    ) -> TrackedJourneyPlan {
        makePlan(
            outbound: direction(segments, fingerprint: "outbound"),
            returnDirection: returnSegments.map { direction($0, fingerprint: "return") }
        )
    }

    private func direction(_ segments: [JourneyPlanSegment], fingerprint: String) -> JourneyPlanDirection {
        JourneyPlanDirection(
            fingerprint: fingerprint, departure: segments.first?.departure ?? date(0),
            arrival: segments.last?.arrival ?? date(60), childTripIDs: segments.compactMap(\.resolvedTripID),
            selectedSegments: segments
        )
    }

    private func makePlan(
        outbound: JourneyPlanDirection, returnDirection: JourneyPlanDirection?
    ) -> TrackedJourneyPlan {
        TrackedJourneyPlan(
            id: UUID(), createdAt: date(-120), origin: place("A"), destination: place("B"),
            outbound: outbound, returnDirection: returnDirection, preExistingChildTripIDs: []
        )
    }

    private func train(for segment: JourneyPlanSegment) -> TrainTrip {
        train(segment.resolvedTripID?.nativeID ?? segment.id, stops: [
            stop(segment.from.displayName, sequence: 1, departure: segment.departure.map { $0.timeIntervalSince(originDate) / 60 }),
            stop(segment.to.displayName, sequence: 2, arrival: segment.arrival.map { $0.timeIntervalSince(originDate) / 60 }),
        ])
    }

    private func train(_ name: String, stops: [StopTime]) -> TrainTrip {
        TrainTrip(
            id: id(name), source: "test", serviceDate: originDate, operatorName: "Rail",
            product: name, headsign: "Destination", stopTimes: stops,
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: false, hasRealtimeDelays: true,
                hasAlerts: false, granularity: .perStop
            )
        )
    }

    private func stop(
        _ name: String, sequence: Int, arrival: Double? = nil, departure: Double? = nil,
        expectedArrival: Double? = nil, cancelled: Bool = false, passed: Bool = false
    ) -> StopTime {
        StopTime(
            station: Station(
                id: id(name), names: [LocalizedStationName(name)],
                location: GeoCoordinate(latitude: 0, longitude: 0), countryCode: "GB"
            ),
            sequence: sequence, scheduledArrival: arrival.map(date), scheduledDeparture: departure.map(date),
            expectedArrival: expectedArrival.map(date), isCancelled: cancelled, isPassed: passed
        )
    }
}
