import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class JourneyExperiencePresentationTests: XCTestCase {
    func testSelectedBoardingAndAlightingControlTitleStopsAndJourneyEnd() throws {
        let trip = makeTrip()
        let selected = segment(trip, boarding: 1, alighting: 3)
        let presentation = present(trip, at: base.addingTimeInterval(125 * 60), selected: selected)

        XCTAssertEqual(presentation.routeTitle, "Station 1 → Station 3")
        XCTAssertEqual(presentation.progress.stops.map(\.station.id), Array(trip.stopTimes[1...3]).map(\.station.id))
        XCTAssertEqual(presentation.progress.phase, .underway)
        XCTAssertEqual(presentation.focusName, "Station 3")
        XCTAssertEqual(presentation.focusDate, trip.stopTimes[3].scheduledArrival)
        let ended = present(trip, at: base.addingTimeInterval(181 * 60), selected: selected)
        XCTAssertEqual(ended.progress.phase, .ended)
        XCTAssertEqual(ended.focusName, "Station 3")
        XCTAssertNil(ended.stationMapURL)
        XCTAssertNil(ended.countdownText)
    }

    func testOpaqueJourneyPlaceIDsStillSelectTheResolvedTripLegByLocation() {
        let trip = makeTrip()
        let selected = segment(trip, boarding: 1, alighting: 3)
        let opaque = JourneyPlanSegment(
            id: selected.id,
            kind: .rail,
            from: opaquePlace(selected.from, suffix: "search-origin"),
            to: opaquePlace(selected.to, suffix: "search-destination"),
            departure: selected.departure,
            arrival: selected.arrival,
            resolvedTripID: trip.id
        )

        let presentation = present(
            trip,
            at: base.addingTimeInterval(125 * 60),
            selected: opaque
        )

        XCTAssertEqual(presentation.progress.phase, .underway)
        XCTAssertEqual(
            presentation.progress.stops.map(\.station.id),
            Array(trip.stopTimes[1...3]).map(\.station.id)
        )
        XCTAssertFalse(presentation.supportingText.contains("couldn’t be matched"))
    }

    func testUnmatchedChosenStationMakesContextUnavailableWithoutFullRouteFallback() {
        let trip = makeTrip()
        let selected = JourneyPlanSegment(
            id: "unmatched", kind: .rail,
            from: place(station(99), zone: "America/New_York"),
            to: place(trip.stopTimes[3].station, zone: "America/New_York"),
            resolvedTripID: trip.id
        )
        let presentation = present(trip, at: base.addingTimeInterval(125 * 60), selected: selected)

        XCTAssertEqual(presentation.progress.phase, .unavailable)
        XCTAssertTrue(presentation.progress.stops.isEmpty)
        XCTAssertEqual(presentation.routeTitle, "Station 99 → Station 3")
        XCTAssertTrue(presentation.supportingText.contains("couldn’t be matched"))
        XCTAssertNil(presentation.focusDate)
        XCTAssertNil(presentation.stationMapURL)
    }

    func testSharedFullTripDoesNotAutomaticallySelectAnOwningPlan() {
        let trip = makeTrip()
        let first = segment(trip, boarding: 0, alighting: 2)
        let second = segment(trip, boarding: 2, alighting: 4)
        let plans = [plan(trip, segments: [first]), plan(trip, segments: [second])]

        XCTAssertEqual(JourneyTripContext.selectedSegment(for: trip.id, plans: [plans[0]]), first)
        XCTAssertNil(JourneyTripContext.selectedSegment(for: trip.id, plans: plans))
        XCTAssertNil(JourneyTripContext.selectedSegment(for: trip.id, plans: Array(plans.reversed())))
    }

    func testRepeatedDirectionOrLegacyOwnershipDoesNotInventSelectedScope() {
        let trip = makeTrip()
        let selected = segment(trip, boarding: 1, alighting: 3)
        let repeated = plan(trip, segments: [selected, selected])
        let roundTrip = plan(trip, segments: [selected], includesReturn: true)
        let legacy = plan(trip, segments: nil)

        for owner in [repeated, roundTrip, legacy] {
            XCTAssertNil(JourneyTripContext.selectedSegment(for: trip.id, plans: [owner]))
        }
    }

    func testCancelledJourneyOffersNoStationMapOrTimeTarget() {
        let trip = makeTrip(cancelled: true)
        let presentation = present(trip, at: base.addingTimeInterval(30 * 60))

        XCTAssertTrue(presentation.progress.isCancelled)
        XCTAssertEqual(presentation.phaseTitle, "Canceled")
        XCTAssertTrue(presentation.isDisrupted)
        XCTAssertNil(presentation.progress.focusStop)
        XCTAssertNil(presentation.stationMapURL)
        XCTAssertNil(presentation.focusDate)
        XCTAssertNil(presentation.countdownText)
        XCTAssertEqual(presentation.platformGuidance, .unavailable)
    }

    func testFreshVehiclePositionAndOtherTripCheckDoNotMakeUncheckedTimesLive() {
        let now = base.addingTimeInterval(30 * 60)
        let checked = present(makeTrip(id: "checked", estimated: true), at: now, checked: now)
        let unchecked = present(makeTrip(id: "unchecked", estimated: true), at: now)

        XCTAssertFalse(checked.needsRefresh)
        XCTAssertTrue(unchecked.needsRefresh)
        XCTAssertFalse(unchecked.trip.positions.isEmpty)
        XCTAssertTrue(unchecked.checkText.contains("Not checked"))
        XCTAssertTrue(unchecked.focusLabel.contains("saved times"))
        XCTAssertEqual(unchecked.progress.focusStop?.id, unchecked.trip.stopTimes.first?.id,
                       "Fresh train GPS remains at the origin despite the departure time passing")
        XCTAssertEqual(unchecked.timingLabel, "Saved departure")
        assertNoLiveClaim(unchecked)
    }

    func testStaleAndFailedRefreshRetainSavedEstimateHonestyPerTrip() {
        let now = base.addingTimeInterval(30 * 60)
        let stale = present(makeTrip(estimated: true), at: now, checked: now.addingTimeInterval(-601))
        let failed = present(makeTrip(estimated: true), at: now, checked: now.addingTimeInterval(-30), failed: true)

        XCTAssertTrue(stale.checkText.contains("10 min ago"))
        XCTAssertEqual(failed.checkText, "Check failed · Saved times shown")
        for presentation in [stale, failed] {
            XCTAssertTrue(presentation.needsRefresh)
            XCTAssertEqual(presentation.progress.focusStop?.id, presentation.trip.stopTimes.first?.id,
                           "Fresh origin GPS keeps the departure in focus without refreshing saved times")
            XCTAssertEqual(presentation.timingLabel, "Saved departure")
            XCTAssertTrue(presentation.supportingText.contains("Saved estimates"))
            assertNoLiveClaim(presentation)
        }
    }

    func testOnlyCurrentlyValidAlertsAffectDisruptionAndSeverityOrder() {
        let now = base.addingTimeInterval(30 * 60)
        let expired = alert("expired", severity: .critical, until: now)
        let future = alert("future", severity: .critical, from: now.addingTimeInterval(1))
        let minor = alert("minor", severity: .minor)
        let current = alert("current", severity: .major, from: now, until: now.addingTimeInterval(60))
        let presentation = present(makeTrip(alerts: [expired, minor, future, current]), at: now)

        XCTAssertEqual(presentation.currentAlerts.map(\.id), [current.id, minor.id])
        XCTAssertTrue(presentation.isDisrupted)
        let inactiveOnly = present(makeTrip(alerts: [expired, future]), at: now)
        XCTAssertTrue(inactiveOnly.currentAlerts.isEmpty)
        XCTAssertFalse(inactiveOnly.isDisrupted)
    }

    func testMidnightFocusUsesStationLocalDayAndClockOnAnEarlierDeviceDay() throws {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = zone("America/Los_Angeles")
        defer { NSTimeZone.default = previousZone }
        let departure = date("2026-09-07T03:50:00Z")
        let focus = date("2026-09-07T04:10:00Z")
        let trip = makeTrip(times: [departure, focus, date("2026-09-07T05:00:00Z")])
        let context = TripDetailTimeZoneContext(
            trip: trip,
            routeTimeZones: .init(departureTimeZoneIdentifier: "America/New_York", arrivalTimeZoneIdentifier: "America/New_York")
        )
        let presentation = JourneyExperiencePresentation(
            trip: trip, timeZones: context, referenceDate: date("2026-09-07T03:55:00Z")
        )
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = zone("America/New_York")

        XCTAssertEqual(presentation.progress.phase, .underway)
        XCTAssertEqual(presentation.focusDate, focus)
        XCTAssertEqual(presentation.focusTimeZone, "America/New_York")
        XCTAssertEqual(eastern.component(.day, from: departure), 6)
        XCTAssertEqual(eastern.component(.day, from: focus), 7)
        XCTAssertEqual(eastern.component(.hour, from: focus), 0)
        XCTAssertEqual(presentation.focusTimeText, clock(focus, zone: "America/New_York"))
        XCTAssertNotEqual(presentation.focusTimeText, clock(focus, zone: "America/Los_Angeles"))
        XCTAssertEqual(presentation.countdownText, "In 15 min")
        XCTAssertNotEqual(
            JourneyExperienceClock.date(departure, zone: "America/New_York"),
            JourneyExperienceClock.date(focus, zone: "America/New_York")
        )
    }

    func testCrossZoneFocusUsesIntermediateStopZoneThenDestinationZoneAfterEnd() throws {
        let fixture = TripDetailTimeZoneFixtures.westernRoute()
        let context = TripDetailTimeZoneContext(trip: fixture.trip, plans: [fixture.plan, fixture.denverPlan])
        let underway = JourneyExperiencePresentation(
            trip: fixture.trip, timeZones: context, referenceDate: date("2026-09-15T21:00:00Z")
        )
        let focused = try XCTUnwrap(underway.focusDate)

        XCTAssertEqual(underway.focusName, "Denver Union Station")
        XCTAssertEqual(underway.focusTimeZone, "America/Denver")
        XCTAssertEqual(underway.focusTimeText, clock(focused, zone: "America/Denver"))
        XCTAssertNotEqual(underway.focusTimeText, clock(focused, zone: "America/Chicago"))
        let ended = JourneyExperiencePresentation(
            trip: fixture.trip, timeZones: context, referenceDate: date("2026-09-16T04:00:00Z")
        )
        XCTAssertEqual(ended.progress.phase, .ended)
        XCTAssertEqual(ended.focusTimeZone, "America/Los_Angeles")
        XCTAssertEqual(ended.focusTimeText, clock(try XCTUnwrap(ended.focusDate), zone: "America/Los_Angeles"))
    }

    func testEndedIntermediateDestinationUsesItsZoneWhileTheFullTrainContinues() throws {
        let fixture = TripDetailTimeZoneFixtures.westernRoute()
        let selected = JourneyPlanSegment(
            id: "chicago-denver", kind: .rail,
            from: fixture.plan.origin, to: fixture.denverPlan.origin,
            departure: fixture.trip.stopTimes[0].scheduledDeparture,
            arrival: fixture.trip.stopTimes[1].scheduledArrival, resolvedTripID: fixture.trip.id
        )
        let context = TripDetailTimeZoneContext(
            trip: fixture.trip, plans: [fixture.plan, fixture.denverPlan],
            additionalPlaces: [selected.from, selected.to]
        )
        let presentation = JourneyExperiencePresentation(
            trip: fixture.trip, timeZones: context, referenceDate: date("2026-09-15T23:00:00Z"),
            selectedSegment: selected
        )

        XCTAssertEqual(presentation.progress.phase, .ended)
        XCTAssertEqual(presentation.focusName, "Denver Union Station")
        XCTAssertEqual(context.routeTimeZones?.arrivalTimeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(presentation.focusTimeZone, "America/Denver")
        let arrival = try XCTUnwrap(presentation.focusDate)
        XCTAssertEqual(arrival, selected.arrival)
        XCTAssertEqual(presentation.focusTimeText, clock(arrival, zone: "America/Denver"))
        XCTAssertNotEqual(presentation.focusTimeText, clock(arrival, zone: "America/Los_Angeles"))
    }

    func testCancelledSelectedBoardingOrAlightingSuppressesTravelTargets() {
        for cancelledIndex in [1, 3] {
            let trip = makeTrip(cancelledStopIndices: [cancelledIndex])
            let presentation = present(
                trip, at: base.addingTimeInterval(75 * 60),
                selected: segment(trip, boarding: 1, alighting: 3)
            )

            XCTAssertFalse(trip.isCancelled)
            XCTAssertFalse(presentation.progress.isCancelled)
            XCTAssertEqual(presentation.phaseTitle, "Stop canceled")
            XCTAssertEqual(presentation.focusName, "Station \(cancelledIndex)")
            XCTAssertNil(presentation.focusDate)
            XCTAssertNil(presentation.stationMapURL)
            XCTAssertEqual(presentation.platformGuidance, .unavailable)
        }
    }

    func testUnderwayScheduledArrivalDoesNotBorrowDepartureEstimateOrDelay() {
        let fixture = makeTrip()
        let arrival = base.addingTimeInterval(60 * 60)
        let middle = StopTime(
            station: fixture.stopTimes[1].station, sequence: 1,
            scheduledArrival: arrival, scheduledDeparture: arrival.addingTimeInterval(5 * 60),
            expectedDeparture: arrival.addingTimeInterval(35 * 60)
        )
        let trip = TrainTrip(
            id: fixture.id, source: fixture.source, serviceDate: fixture.serviceDate,
            operatorName: fixture.operatorName, product: fixture.product, headsign: fixture.headsign,
            stopTimes: [fixture.stopTimes[0], middle] + Array(fixture.stopTimes.dropFirst(2)),
            capabilities: fixture.capabilities
        )
        let presentation = present(trip, at: base.addingTimeInterval(30 * 60))

        XCTAssertEqual(presentation.progress.phase, .underway)
        XCTAssertEqual(presentation.focusDate, arrival)
        XCTAssertEqual(presentation.timingLabel, "Timetable arrival")
        XCTAssertNil(presentation.delayText)
        XCTAssertFalse(presentation.isDisrupted)
    }

    private var base: Date { date("2026-09-06T12:00:00Z") }

    /// Train 2120 showed "Expected 6:44 PM" for Philadelphia above a route row reading 6:46 PM.
    /// Both were valid: the card shows the next stop's arrival and the row its departure.
    func testNextStopArrivalAndRouteDepartureNameTheirEvents() {
        let fixture = makeTrip()
        let arrival = base.addingTimeInterval(60 * 60)
        let middle = StopTime(
            station: fixture.stopTimes[1].station, sequence: 1,
            scheduledArrival: arrival, scheduledDeparture: arrival.addingTimeInterval(2 * 60),
            expectedArrival: arrival, expectedDeparture: arrival.addingTimeInterval(2 * 60)
        )
        let trip = TrainTrip(
            id: fixture.id, source: fixture.source, serviceDate: fixture.serviceDate,
            operatorName: fixture.operatorName, product: fixture.product, headsign: fixture.headsign,
            stopTimes: [fixture.stopTimes[0], middle] + Array(fixture.stopTimes.dropFirst(2)),
            capabilities: fixture.capabilities
        )
        let now = base.addingTimeInterval(30 * 60)
        let presentation = present(trip, at: now, checked: now)
        XCTAssertEqual(presentation.progress.phase, .underway)
        XCTAssertEqual(presentation.focusDate, arrival)
        XCTAssertEqual(presentation.timingLabel, "Estimated arrival")

        let row = StopTimelineTimePresentation(stop: middle, event: .departure)
        XCTAssertEqual(row.date, arrival.addingTimeInterval(2 * 60))
        XCTAssertEqual(row.eventNoun, "departure")

        let departureOnly = StopTime(station: middle.station, sequence: 1, expectedDeparture: arrival)
        let fallback = StopTimelineTimePresentation(stop: departureOnly, event: .arrival)
        XCTAssertEqual(fallback.date, arrival)
        XCTAssertEqual(fallback.eventNoun, "departure", "A fallback time is not relabelled as an arrival")

        let before = present(trip, at: base.addingTimeInterval(-20 * 60), checked: base.addingTimeInterval(-20 * 60))
        XCTAssertTrue(before.timingLabel.hasSuffix("departure"), before.timingLabel)
    }

    private func present(
        _ trip: TrainTrip, at now: Date, checked: Date? = nil,
        failed: Bool = false, selected: JourneyPlanSegment? = nil
    ) -> JourneyExperiencePresentation {
        JourneyExperiencePresentation(
            trip: trip, timeZones: TripDetailTimeZoneContext(trip: trip), referenceDate: now,
            lastSuccessfulCheck: checked, refreshFailed: failed, selectedSegment: selected
        )
    }

    private func makeTrip(
        id: String = "full-route", times: [Date]? = nil, estimated: Bool = false,
        cancelled: Bool = false, cancelledStopIndices: Set<Int> = [], alerts: [RailAlert] = []
    ) -> TrainTrip {
        let times = times ?? (0..<5).map { base.addingTimeInterval(Double($0) * 3_600) }
        let stops = times.enumerated().map { index, time in
            StopTime(
                station: station(index), sequence: index,
                scheduledArrival: index == 0 ? nil : time,
                scheduledDeparture: index == times.count - 1 ? nil : time,
                expectedArrival: estimated && index > 0 ? time.addingTimeInterval(60) : nil,
                expectedDeparture: estimated && index < times.count - 1 ? time.addingTimeInterval(60) : nil,
                plannedPlatform: "2", isCancelled: cancelled || cancelledStopIndices.contains(index)
            )
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:fixture:\(id)"), source: "fixture", serviceDate: times[0],
            operatorName: "Fixture Rail", product: "Express", headsign: stops.last!.station.displayName,
            stopTimes: stops,
            positions: [.init(coordinate: stops[0].station.location, source: .real, confidence: 1, asOf: base.addingTimeInterval(30 * 60))],
            alerts: alerts,
            capabilities: .init(hasPositions: true, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: true, granularity: .perStop)
        )
    }

    private func segment(_ trip: TrainTrip, boarding: Int, alighting: Int) -> JourneyPlanSegment {
        JourneyPlanSegment(
            id: "\(boarding)-\(alighting)", kind: .rail,
            from: place(trip.stopTimes[boarding].station, zone: "America/New_York"),
            to: place(trip.stopTimes[alighting].station, zone: "America/New_York"),
            departure: trip.stopTimes[boarding].scheduledDeparture,
            arrival: trip.stopTimes[alighting].scheduledArrival, resolvedTripID: trip.id
        )
    }

    private func plan(
        _ trip: TrainTrip, segments: [JourneyPlanSegment]?, includesReturn: Bool = false
    ) -> TrackedJourneyPlan {
        let direction = JourneyPlanDirection(
            fingerprint: "selected", departure: base, arrival: base.addingTimeInterval(14_400),
            childTripIDs: [trip.id], selectedSegments: segments
        )
        return TrackedJourneyPlan(
            id: UUID(), createdAt: base,
            origin: place(trip.origin!, zone: "America/New_York"),
            destination: place(trip.destination!, zone: "America/New_York"),
            outbound: direction, returnDirection: includesReturn ? direction : nil, preExistingChildTripIDs: []
        )
    }

    private func station(_ index: Int) -> Station {
        Station(
            id: RailIdentifier(rawValue: "us:fixture:station-\(index)"), names: [.init("Station \(index)")],
            location: .init(latitude: 40 + Double(index) * 0.1, longitude: -74), countryCode: "US"
        )
    }

    private func place(_ station: Station, zone: String) -> RailPlace {
        RailPlace(
            id: station.id, kind: .station, displayName: station.displayName,
            context: "", countryCode: "US", timeZoneIdentifier: zone,
            location: station.location, eligibleModes: ["longDistanceRail"], attributions: []
        )
    }

    private func opaquePlace(_ place: RailPlace, suffix: String) -> RailPlace {
        let payload = Data("\(suffix)\u{1f}\(place.countryCode)\u{1f}\u{1f}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return RailPlace(
            id: RailIdentifier(rawValue: "rail:transitous:station:\(payload)"),
            kind: .station,
            displayName: place.displayName,
            context: place.context,
            countryCode: place.countryCode,
            timeZoneIdentifier: place.timeZoneIdentifier,
            location: place.location,
            eligibleModes: place.eligibleModes,
            attributions: place.attributions
        )
    }

    private func alert(_ id: String, severity: AlertSeverity, from: Date? = nil, until: Date? = nil) -> RailAlert {
        RailAlert(id: RailIdentifier(rawValue: "us:fixture:\(id)"), severity: severity, message: id, validFrom: from, validUntil: until)
    }

    private func assertNoLiveClaim(
        _ presentation: JourneyExperiencePresentation, file: StaticString = #filePath, line: UInt = #line
    ) {
        let copy = [presentation.checkText, presentation.focusLabel, presentation.timingLabel, presentation.supportingText].joined(separator: " ")
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("live"), file: file, line: line)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier)! }

    private func clock(_ date: Date, zone identifier: String) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .autoupdatingCurrent, timeZone: zone(identifier)))
    }
}
