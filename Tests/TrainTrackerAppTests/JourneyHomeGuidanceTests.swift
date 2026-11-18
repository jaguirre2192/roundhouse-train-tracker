import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyHomeGuidanceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testCurrentJourneyWinsAndClockStagesAreLabelledAsTimetableEstimates() {
        let current = plan("current", [rail("now", from: "A", to: "B", departure: -10, arrival: 50)])
        let upcoming = plan("upcoming", [rail("soon", from: "C", to: "D", departure: 20, arrival: 80)])
        let trips = [train(for: current), train(for: upcoming)].flatMap { $0 }
        let focus = JourneyHomeGuidance.select(plans: [upcoming, current], trips: trips, at: date(0))
        XCTAssertEqual(focus?.plan.id, current.id)
        XCTAssertEqual(focus?.title, "Underway by timetable")

        let beforeBoth = JourneyHomeGuidance.select(plans: [upcoming, current], trips: trips, at: date(-40))
        XCTAssertEqual(beforeBoth?.plan.id, current.id)
        XCTAssertEqual(beforeBoth?.title, "Departs soon")
        let farAhead = JourneyHomeGuidance.select(plans: [upcoming], trips: trips, at: date(-120))
        XCTAssertEqual(farAhead?.title, "Your next journey")
    }

    func testCompletedJourneyYieldsToUpcomingTravelAndHasNoHomeFocus() {
        let finished = plan("finished", [rail("done", from: "A", to: "B", departure: -120, arrival: -30)])
        let later = plan("later", [rail("later", from: "B", to: "C", departure: 300, arrival: 360)])
        let soon = plan("soon", [rail("soon", from: "B", to: "C", departure: 60, arrival: 120)])
        let trips = [finished, later, soon].flatMap(train(for:))

        let next = JourneyHomeGuidance.select(plans: [finished, later], trips: trips, at: date(0))
        XCTAssertEqual(next?.plan.id, later.id)
        XCTAssertFalse(next?.isRecentCompletion == true)
        XCTAssertEqual(next?.title, "Your next journey")
        XCTAssertNil(JourneyHomeGuidance.select(plans: [finished], trips: trips, at: date(0)))

        XCTAssertEqual(JourneyHomeGuidance.select(plans: [finished, soon], trips: trips, at: date(0))?.plan.id, soon.id)
        XCTAssertEqual(JourneyHomeGuidance.select(plans: [finished, later], trips: trips, at: date(200))?.plan.id, later.id,
                       "Completed travel remains in history while the next journey is actionable")
        XCTAssertNil(JourneyHomeGuidance.select(plans: [finished], trips: trips, at: date(200)))
    }

    func testTrainContinuingBeyondAlightingStationDoesNotExtendJourney() {
        let selected = rail("through", from: "A", to: "B", departure: 0, arrival: 60)
        let saved = plan("through", [selected])
        let longTrain = trainTrip("through", stops: [
            stop("A", sequence: 1, departure: 0),
            stop("B", sequence: 2, arrival: 60),
            stop("Terminus", sequence: 3, arrival: 600),
        ])
        let focus = JourneyHomeGuidance.select(plans: [saved], trips: [longTrain], at: date(59))
        XCTAssertEqual(focus?.plan.id, saved.id)
        XCTAssertEqual(focus?.endDate, date(60))
        XCTAssertEqual(JourneyHomeGuidance.effectiveArrival(for: saved.outbound, trips: [longTrain], at: date(61)), date(60))
        XCTAssertNil(JourneyHomeGuidance.select(plans: [saved], trips: [longTrain], at: date(61)))
        let list = JourneyPlanListPresentation(plans: [saved], trips: [longTrain], activeTrip: longTrain, at: date(61))
        XCTAssertEqual(list.pastJourneys(asOf: date(61)).map(\.id), [saved.id])
        XCTAssertNil(list.activeTrip, "The continuing train cannot revive its passenger-completed journey")
        XCTAssertTrue(list.individualTrips.isEmpty)
    }

    func testReturnDirectionUsesReturnEndpointsAndLabels() {
        let outbound = rail("out", from: "A", to: "B", departure: 0, arrival: 60)
        let back = rail("back", from: "B", to: "A", departure: 240, arrival: 300)
        let saved = plan("round", [outbound], returnSegments: [back])
        let trips = train(for: saved)
        let focus = JourneyHomeGuidance.select(plans: [saved], trips: trips, at: date(250))
        XCTAssertEqual(focus?.title, "Return underway by timetable")
        XCTAssertEqual(focus?.origin.displayName, "B")
        XCTAssertEqual(focus?.destination.displayName, "A")
    }

    func testConnectionCopyReportsIntervalsWithoutPromisingFeasibility() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let late = trainTrip("first", stops: [stop("A", sequence: 1, departure: 0), stop("B", sequence: 2, arrival: 30, expectedArrival: 50)])
        let saved = plan("connection", [first, next])
        let stage = JourneyPlanStage(plan: saved, trips: [late] + train(for: plan("n", [next])), referenceDate: date(55))
        let focus = JourneyHomeGuidance.select(plans: [saved], trips: [late] + train(for: plan("n", [next])), at: date(55))
        XCTAssertEqual(focus?.title, "Connection by timetable")
        let connection = try? XCTUnwrap(stage.connection)
        XCTAssertEqual(
            connection.flatMap(JourneyHomeGuidance.connectionText),
            "Saved interval: 30 min. Last estimated interval: 10 min. This is time between trains, not confirmation that the connection is possible."
        )

        let request = JourneyHomeGuidance.alternatives(stage: stage, at: date(55))
        XCTAssertEqual(request?.originName, "B")
        XCTAssertEqual(request?.destinationName, "C")
        XCTAssertEqual(request?.departureTime, ISO8601DateFormatter().string(from: date(60)))
        XCTAssertNil(request?.trainNumber, "Alternatives are a search, never a rebooking of the saved train")
    }

    func testAlternativesStartFromTheAffectedLegAndNeverInThePast() {
        let first = rail("first", from: "A", to: "B", departure: 0, arrival: 30)
        let next = rail("next", from: "B", to: "C", departure: 60, arrival: 90)
        let saved = plan("legs", [first, next])
        let trips = train(for: saved)
        let stage = JourneyPlanStage(plan: saved, trips: trips, referenceDate: date(10))
        let request = JourneyHomeGuidance.alternatives(stage: stage, at: date(10))
        XCTAssertEqual(request?.originName, "A")
        XCTAssertEqual(request?.destinationName, "C")
        XCTAssertEqual(request?.departureTime, ISO8601DateFormatter().string(from: date(10)))
    }

    func testArrivalTextDistinguishesScheduledExpectedAndStaleEstimates() {
        let selected = rail("arr", from: "A", to: "B", departure: 0, arrival: 60)
        let scheduled = trainTrip("arr", stops: [stop("A", sequence: 1, departure: 0), stop("B", sequence: 2, arrival: 60)])
        let delayed = trainTrip("arr", stops: [stop("A", sequence: 1, departure: 0), stop("B", sequence: 2, arrival: 60, expectedArrival: 72)])
        func text(_ trip: TrainTrip, check: Date?) -> String? {
            let presentation = JourneyExperiencePresentation(
                trip: trip, timeZones: TripDetailTimeZoneContext(trip: trip, plans: [], additionalPlaces: [selected.from, selected.to]),
                referenceDate: date(10), lastSuccessfulCheck: check, selectedSegment: selected
            )
            return JourneyHomeGuidance.arrivalText(presentation)
        }
        XCTAssertTrue(text(scheduled, check: date(9))?.hasPrefix("Timetable arrival at B") == true)
        let fresh = text(delayed, check: date(9))
        XCTAssertTrue(fresh?.hasPrefix("Estimated arrival at B") == true)
        XCTAssertTrue(fresh?.hasSuffix("12 min late") == true)
        XCTAssertTrue(text(delayed, check: nil)?.hasPrefix("Last arrival estimate at B") == true)
    }

    func testDirectionsNeedRealCoordinates() {
        XCTAssertNil(JourneyHomeGuidance.directionsURL(to: place("A")))
        let located = RailPlace(
            id: RailIdentifier(rawValue: "x"), kind: .station, displayName: "Real", context: "", countryCode: "GB",
            timeZoneIdentifier: "Europe/London", location: GeoCoordinate(latitude: 51.53, longitude: -0.12),
            eligibleModes: [], attributions: []
        )
        let url = JourneyHomeGuidance.directionsURL(to: located)
        XCTAssertEqual(url?.host, "maps.apple.com")
        XCTAssertTrue(url?.query?.contains("daddr=51.53,-0.12") == true)
    }

    // MARK: - Fixtures

    private func date(_ minutes: Double) -> Date { origin.addingTimeInterval(minutes * 60) }
    private func id(_ name: String) -> RailIdentifier { RailIdentifier(rawValue: "eu:test:\(name)") }

    private func place(_ name: String) -> RailPlace {
        RailPlace(
            id: id(name), kind: .station, displayName: name, context: "", countryCode: "GB",
            timeZoneIdentifier: "Europe/London", location: GeoCoordinate(latitude: 0, longitude: 0),
            eligibleModes: ["regionalRail"], attributions: []
        )
    }

    private func rail(_ name: String, from: String, to: String, departure: Double, arrival: Double) -> JourneyPlanSegment {
        JourneyPlanSegment(
            id: name, kind: .rail, from: place(from), to: place(to),
            departure: date(departure), arrival: date(arrival), serviceName: name, resolvedTripID: id(name)
        )
    }

    private func plan(_ name: String, _ segments: [JourneyPlanSegment], returnSegments: [JourneyPlanSegment]? = nil) -> TrackedJourneyPlan {
        func direction(_ segments: [JourneyPlanSegment], _ fingerprint: String) -> JourneyPlanDirection {
            JourneyPlanDirection(
                fingerprint: fingerprint, departure: segments.first?.departure ?? date(0), arrival: segments.last?.arrival ?? date(60),
                childTripIDs: segments.compactMap(\.resolvedTripID), selectedSegments: segments
            )
        }
        return TrackedJourneyPlan(
            id: UUID(), createdAt: date(-500), origin: segments[0].from, destination: segments.last!.to,
            outbound: direction(segments, "\(name)-out"),
            returnDirection: returnSegments.map { direction($0, "\(name)-back") }, preExistingChildTripIDs: []
        )
    }

    private func train(for plan: TrackedJourneyPlan) -> [TrainTrip] {
        let segments = (plan.outbound.selectedSegments ?? []) + (plan.returnDirection?.selectedSegments ?? [])
        return segments.filter { $0.kind == .rail }.map { segment in
            trainTrip(segment.id, stops: [
                stop(segment.from.displayName, sequence: 1, departure: segment.departure.map { $0.timeIntervalSince(origin) / 60 }),
                stop(segment.to.displayName, sequence: 2, arrival: segment.arrival.map { $0.timeIntervalSince(origin) / 60 }),
            ])
        }
    }

    private func trainTrip(_ name: String, stops: [StopTime]) -> TrainTrip {
        TrainTrip(
            id: id(name), source: "test", serviceDate: origin, operatorName: "Rail", product: name, headsign: "Destination",
            stopTimes: stops,
            capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }

    private func stop(_ name: String, sequence: Int, arrival: Double? = nil, departure: Double? = nil, expectedArrival: Double? = nil) -> StopTime {
        StopTime(
            station: Station(id: id(name), names: [LocalizedStationName(name)], location: GeoCoordinate(latitude: 0, longitude: 0), countryCode: "GB"),
            sequence: sequence, scheduledArrival: arrival.map(date), scheduledDeparture: departure.map(date),
            expectedArrival: expectedArrival.map(date)
        )
    }
}
