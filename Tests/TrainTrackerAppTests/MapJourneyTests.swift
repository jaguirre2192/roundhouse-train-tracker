import CoreLocation
import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

/// The map-backed journey: the trust word, the panel's heights, the train carried between
/// reports, the travel log and the wake alert.
final class MapJourneyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_789_500_000)
    private func minutes(_ value: Double) -> Date { base.addingTimeInterval(value * 60) }

    // A straight north-south line: one degree of latitude is about 111 km.
    private let line = [
        CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0),
        CLLocationCoordinate2D(latitude: 40.5, longitude: -75.0),
        CLLocationCoordinate2D(latitude: 41.0, longitude: -75.0),
    ]

    private func station(_ code: String, _ name: String, latitude: Double) -> Station {
        Station(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: code),
            names: [LocalizedStationName(name)], codes: [.sourceNative: code],
            location: GeoCoordinate(latitude: latitude, longitude: -75.0), countryCode: "US"
        )
    }

    /// Departs the south end at 0, calls mid-line at 30, arrives north at 60.
    private func trip(positionLatitude: Double? = nil, positionAge: TimeInterval = 0, passedFirst: Bool = true) -> TrainTrip {
        let south = station("STH", "South End", latitude: 40.0)
        let middle = station("MID", "Midtown", latitude: 40.5)
        let north = station("NTH", "North End", latitude: 41.0)
        return TrainTrip(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: "7-1"), source: "amtraker", serviceDate: base,
            operatorName: "Amtrak", product: "Test 7", headsign: "North End",
            stopTimes: [
                StopTime(station: south, sequence: 1, scheduledDeparture: minutes(0), expectedDeparture: minutes(0), isPassed: passedFirst),
                StopTime(station: middle, sequence: 2, scheduledArrival: minutes(30), scheduledDeparture: minutes(31),
                         expectedArrival: minutes(30), expectedDeparture: minutes(31)),
                StopTime(station: north, sequence: 3, scheduledArrival: minutes(60), expectedArrival: minutes(66)),
            ],
            positions: positionLatitude.map {
                [VehiclePosition(coordinate: GeoCoordinate(latitude: $0, longitude: -75.0), source: .real,
                                 confidence: 0.9, asOf: minutes(10).addingTimeInterval(-positionAge))]
            } ?? [],
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: true, granularity: .perStop)
        )
    }

    // MARK: Trust

    func testTrustIsSavedUntilThisSessionChecks() {
        XCTAssertEqual(JourneyTrust(freshness: .notChecked, timingBasis: .estimated, phase: .underway, referenceDate: base), .saved)
        XCTAssertEqual(JourneyTrust(freshness: .checkFailed, timingBasis: .estimated, phase: .underway, referenceDate: base), .saved)
        XCTAssertFalse(JourneyTrust.saved.isConfirmed)
    }

    func testTrustIsLiveOnlyForARunningTrainCheckedRecently() {
        let fresh = TripFreshness.checked(base.addingTimeInterval(-60))
        XCTAssertEqual(JourneyTrust(freshness: fresh, timingBasis: .estimated, phase: .underway, referenceDate: base), .live)
        XCTAssertEqual(JourneyTrust(freshness: fresh, timingBasis: .estimated, phase: .upcoming, referenceDate: base), .estimated)
        XCTAssertEqual(JourneyTrust(freshness: fresh, timingBasis: .scheduled, phase: .underway, referenceDate: base), .timetable)
        let old = TripFreshness.checked(base.addingTimeInterval(-6 * 60))
        XCTAssertEqual(JourneyTrust(freshness: old, timingBasis: .estimated, phase: .underway, referenceDate: base), .estimated)
    }

    func testTrustLineNamesTheWordAndTheCheck() {
        XCTAssertEqual(JourneyTrust.saved.line(freshness: .notChecked, at: base), "Saved · Not checked yet")
        XCTAssertEqual(JourneyTrust.live.line(freshness: .checked(base), at: base), "Live · Checked just now")
    }

    // MARK: Panel

    func testPanelHeightsAreOrderedAndTheMapInsetStopsAtHalf() {
        let metrics = JourneyDrawerMetrics(contentHeight: 700, bottomInset: 34)
        XCTAssertLessThan(metrics.peek, metrics.half)
        XCTAssertLessThan(metrics.half, metrics.full)
        XCTAssertEqual(metrics.mapInset(for: .peek), metrics.peek)
        XCTAssertEqual(metrics.mapInset(for: .full), metrics.half, "At full height the map is no longer the subject")
    }

    func testPanelHeightsStayOrderedOnAVeryShortScreen() {
        let metrics = JourneyDrawerMetrics(contentHeight: 90, bottomInset: 0)
        XCTAssertLessThan(metrics.peek, metrics.half)
        XCTAssertLessThan(metrics.half, metrics.full)
    }

    func testTimeAwayReadsAsABoardWould() {
        XCTAssertEqual(JourneyPeekStrip.timeAway(until: minutes(0), from: minutes(1)), "Now")
        XCTAssertEqual(JourneyPeekStrip.timeAway(until: minutes(12), from: minutes(0)), "12 min")
        XCTAssertEqual(JourneyPeekStrip.timeAway(until: minutes(65), from: minutes(0)), "1 h 05")
    }

    // MARK: Route path and glide

    func testRoutePathMeasuresProjectsAndSlices() throws {
        let path = try XCTUnwrap(RoutePath(coordinates: line))
        XCTAssertEqual(path.length, 111_000, accuracy: 1_500)
        let middle = path.projection(of: CLLocationCoordinate2D(latitude: 40.5, longitude: -74.99))
        XCTAssertEqual(middle.distance, path.length / 2, accuracy: 200)
        XCTAssertEqual(middle.offset, 850, accuracy: 100, "0.01° of longitude at 40.5°N")
        XCTAssertEqual(path.coordinate(at: path.length / 4).latitude, 40.25, accuracy: 0.01)
        let slice = path.slice(from: path.length * 0.25, to: path.length * 0.75)
        XCTAssertEqual(slice.count, 3, "Both ends and the vertex between them")
        XCTAssertEqual(slice.first?.latitude ?? 0, 40.25, accuracy: 0.01)
        XCTAssertEqual(slice.last?.latitude ?? 0, 40.75, accuracy: 0.01)
        XCTAssertNil(RoutePath(coordinates: [line[0]]))
    }

    func testGlideCarriesTheTrainAtThePaceItsNextArrivalImplies() throws {
        let path = try XCTUnwrap(RoutePath(coordinates: line))
        // Reported at 40.25 at minute 10; due at 40.5 at minute 30: about 27.8 km in 20 minutes.
        let trip = trip(positionLatitude: 40.25)
        let glide = try XCTUnwrap(TrainGlide(trip: trip, position: trip.positions[0], path: path, referenceDate: minutes(10)))
        XCTAssertEqual(glide.speed, 27_750.0 / 1_200, accuracy: 0.6)
        XCTAssertEqual(glide.distance(at: minutes(10)), glide.fixDistance, accuracy: 1)
        XCTAssertEqual(glide.distance(at: minutes(11)) - glide.fixDistance, glide.speed * 60, accuracy: 1)
        XCTAssertFalse(glide.isEstimated(at: minutes(10)))
        XCTAssertTrue(glide.isEstimated(at: minutes(11)))
    }

    func testGlideStopsAfterThreeMinutesWithoutAReport() throws {
        let path = try XCTUnwrap(RoutePath(coordinates: line))
        let trip = trip(positionLatitude: 40.25)
        let glide = try XCTUnwrap(TrainGlide(trip: trip, position: trip.positions[0], path: path, referenceDate: minutes(10)))
        XCTAssertEqual(glide.distance(at: minutes(13)), glide.distance(at: minutes(25)), accuracy: 0.001)
    }

    func testGlideNeverPassesTheNextStop() throws {
        let path = try XCTUnwrap(RoutePath(coordinates: line))
        // Reported just short of Midtown, with the arrival seconds away.
        let late = TrainTrip(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: "7-1"), source: "amtraker", serviceDate: base,
            operatorName: "Amtrak", product: "Test 7", headsign: "North End",
            stopTimes: trip().stopTimes,
            positions: [VehiclePosition(coordinate: GeoCoordinate(latitude: 40.495, longitude: -75.0), source: .real,
                                        confidence: 0.9, asOf: minutes(29.5))],
            capabilities: trip().capabilities
        )
        let glide = try XCTUnwrap(TrainGlide(trip: late, position: late.positions[0], path: path, referenceDate: minutes(29.5)))
        let midtown = path.projection(of: line[1]).distance
        XCTAssertLessThan(glide.distance(at: minutes(33)), midtown)
    }

    func testAReportOffTheLineOrAnEstimatedOneIsNotCarried() throws {
        let path = try XCTUnwrap(RoutePath(coordinates: line))
        let trip = trip(positionLatitude: 40.25)
        let offLine = VehiclePosition(coordinate: GeoCoordinate(latitude: 40.25, longitude: -74.9), source: .real, confidence: 0.9, asOf: minutes(10))
        XCTAssertNil(TrainGlide(trip: trip, position: offLine, path: path, referenceDate: minutes(10)), "8 km from the line is not on this line")
        let estimated = VehiclePosition(coordinate: GeoCoordinate(latitude: 40.25, longitude: -75.0), source: .inferred, confidence: 0.5, asOf: minutes(10))
        XCTAssertNil(TrainGlide(trip: trip, position: estimated, path: path, referenceDate: minutes(10)))
    }

    // MARK: Travel log

    func testAFinishedJourneyBecomesAStub() throws {
        let trip = trip()
        let entry = try XCTUnwrap(TravelLogEntry(trip: trip, stops: trip.stopTimes, arrivalConfirmed: true))
        XCTAssertEqual(entry.originLabel, "STH")
        XCTAssertEqual(entry.destinationLabel, "NTH")
        XCTAssertEqual(entry.distanceMeters, 111_000, accuracy: 1_500)
        XCTAssertEqual(entry.duration, 66 * 60, accuracy: 1, "It ran to its estimated arrival")
        XCTAssertEqual(entry.arrivalDelayMinutes, 6)
        XCTAssertEqual(entry.stopCount, 3)
        XCTAssertNil(TravelLogEntry(trip: trip, stops: [trip.stopTimes[0]], arrivalConfirmed: true), "One stop is not a journey")
    }

    @MainActor
    func testTheLogKeepsAJourneyOnceAndTotalsIt() throws {
        let log = TravelLog(seed: [])
        let entry = try XCTUnwrap(TravelLogEntry(trip: trip(), stops: trip().stopTimes, arrivalConfirmed: true))
        XCTAssertTrue(log.record(entry))
        XCTAssertFalse(log.record(entry), "Seeing the same train again adds nothing")
        XCTAssertEqual(log.totals.journeys, 1)
        XCTAssertEqual(log.totals.stations, 2)
        XCTAssertEqual(log.totals.duration, 66 * 60, accuracy: 1)
        log.remove(id: entry.id)
        XCTAssertEqual(log.totals, TravelLog.Totals())
    }

    func testLogDurationsAndDistancesRead() {
        XCTAssertEqual(TravelLogFormat.duration(42 * 60), "42 min")
        XCTAssertEqual(TravelLogFormat.duration(120 * 60), "2 h")
        XCTAssertEqual(TravelLogFormat.duration(218 * 60), "3 h 38 min")
        XCTAssertEqual(TravelLogFormat.distance(160_934, locale: Locale(identifier: "en_US")), "100 mi")
        // French sets the unit off with a narrow no-break space.
        let french = TravelLogFormat.distance(100_000, locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(french.split(whereSeparator: \.isWhitespace).map(String.init), ["100", "km"])
    }

    // MARK: Wake alert

    func testWakePlanAimsAtTheStopAheadWithARadiusFromTheTrainsPace() throws {
        let plan = try XCTUnwrap(StopWakePlan(trip: trip(), stopID: "us:amtraker:NTH", leadMinutes: 10))
        XCTAssertEqual(plan.stopName, "North End")
        XCTAssertEqual(plan.arrival, minutes(66), "The estimate, not the timetable")
        // Midtown to North End is 55.5 km in 35 minutes: about 26 m/s, so 10 minutes is ~15.9 km.
        XCTAssertEqual(plan.radius, 15_860, accuracy: 600)
    }

    func testWakePlanNeverReachesBackToTheStopBefore() throws {
        // Fifteen minutes at this pace is 23.8 km, well inside the 55 km leg.
        let wide = try XCTUnwrap(StopWakePlan(trip: trip(), stopID: "us:amtraker:NTH", leadMinutes: 15))
        XCTAssertLessThan(wide.radius, 55_500 * 0.8 + 1)
        XCTAssertGreaterThanOrEqual(wide.radius, StopWakePlan.shortestRadius)
    }

    func testNoWakePlanForTheFirstStopOrAnUnknownOne() {
        XCTAssertNil(StopWakePlan(trip: trip(), stopID: "us:amtraker:STH", leadMinutes: 10))
        XCTAssertNil(StopWakePlan(trip: trip(), stopID: "us:amtraker:XXX", leadMinutes: 10))
    }

    // MARK: Lock Screen starts itself

    /// The same line as `trip()`, timed against a departure the test chooses.
    private func departing(inMinutes minutes: Double) -> TrainTrip {
        let start = base.addingTimeInterval(minutes * 60)
        let south = station("STH", "South End", latitude: 40.0)
        let north = station("NTH", "North End", latitude: 41.0)
        return TrainTrip(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: "9-1"), source: "amtraker", serviceDate: base,
            operatorName: "Amtrak", product: "Test 9", headsign: "North End",
            stopTimes: [
                StopTime(station: south, sequence: 1, scheduledDeparture: start),
                StopTime(station: north, sequence: 2, scheduledArrival: start.addingTimeInterval(3_600)),
            ],
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: true, granularity: .perStop)
        )
    }

    @MainActor
    private func autoStartCandidate(_ trip: TrainTrip, started: Set<String> = []) -> TrainTrip? {
        LockScreenAutoStart.candidate(
            trips: [trip], plans: [], at: base, alreadyStarted: started,
            lastSuccessfulCheck: { _ in self.base }, lastRefreshFailed: { _ in false }
        )?.trip
    }

    @MainActor
    func testATrainLeavingWithinTheHourGoesOnTheLockScreen() {
        XCTAssertNotNil(autoStartCandidate(departing(inMinutes: 30)), "Half an hour out is inside the window")
        XCTAssertNotNil(autoStartCandidate(departing(inMinutes: -10)), "A train underway is inside the window")
    }

    @MainActor
    func testATrainHoursAwayDoesNotStartYet() {
        XCTAssertNil(autoStartCandidate(departing(inMinutes: 180)))
    }

    @MainActor
    func testATrainIsStartedAutomaticallyOnlyOnce() {
        let trip = departing(inMinutes: 30)
        XCTAssertNil(autoStartCandidate(trip, started: [trip.id.rawValue]), "Ended by hand, it does not come back")
    }

    // MARK: Widget countdown

    func testWidgetCountsDownOnlyWhenTheTrainIsClose() throws {
        let snapshot = NextTrainWidgetSamples.snapshot(for: .upcoming, at: base)
        guard case let .train(train, _) = WidgetDisplay(snapshot: snapshot, at: base) else { return XCTFail("No sample train") }
        let near = WidgetTrainPresentation(train: train, at: base)
        let anchor = try XCTUnwrap(near.anchorDate)
        let minutes = Int((anchor.timeIntervalSince(base) / 60).rounded(.up))
        XCTAssertEqual(near.countdownText, "\(minutes) min", "Inside ninety minutes the answer is how long")
        XCTAssertTrue(near.countdownLabel.hasPrefix("Leaves "), near.countdownLabel)

        let far = WidgetTrainPresentation(train: train, at: anchor.addingTimeInterval(-3 * 3_600))
        XCTAssertNil(far.countdownText, "Hours out, the clock time is the answer")
        XCTAssertEqual(WidgetTrainPresentation(train: train, at: anchor.addingTimeInterval(-65 * 60)).countdownText, "1 h 05")
    }

    func testWidgetTimelineHasAnEntryForEachMinuteOfTheCountdown() throws {
        let snapshot = NextTrainWidgetSamples.snapshot(for: .upcoming, at: base)
        guard case let .train(train, _) = WidgetDisplay(snapshot: snapshot, at: base) else { return XCTFail("No sample train") }
        let anchor = try XCTUnwrap(WidgetTrainPresentation(train: train, at: base).anchorDate)
        let ticks = NextTrainProvider.countdownTicks(snapshot: snapshot, from: base)
        XCTAssertEqual(ticks.count, Int((anchor.timeIntervalSince(base) / 60).rounded(.up)))
        XCTAssertEqual(ticks.last, anchor, "The last entry is the moment itself")
        XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { abs($1.timeIntervalSince($0) - 60) < 0.001 })
        XCTAssertTrue(NextTrainProvider.countdownTicks(snapshot: snapshot, from: anchor.addingTimeInterval(-3 * 3_600)).isEmpty)
    }
}
