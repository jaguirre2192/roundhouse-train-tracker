import CoreLocation
import Foundation
import TrainTrackerCore
import UIKit
import XCTest
@testable import TrainTracker

/// The first-run train, the panel-to-map link, the status words and the share picture.
@MainActor
final class AwardPassTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_789_500_000)
    private func minutes(_ value: Double) -> Date { base.addingTimeInterval(value * 60) }

    private func station(_ code: String, latitude: Double, longitude: Double = -75.0) -> Station {
        Station(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: code),
            names: [LocalizedStationName(code)], codes: [.sourceNative: code],
            location: GeoCoordinate(latitude: latitude, longitude: longitude), countryCode: "US"
        )
    }

    /// A track from 40°N to 41°N along 75°W, as the standard encoded polyline.
    private static var straightTrack: RouteGeometry {
        func encode(_ value: Int) -> String {
            var remaining = value < 0 ? ~(value << 1) : value << 1
            var text = ""
            while remaining >= 0x20 {
                text.append(Character(UnicodeScalar(UInt8((0x20 | (remaining & 0x1f)) + 63))))
                remaining >>= 5
            }
            text.append(Character(UnicodeScalar(UInt8(remaining + 63))))
            return text
        }
        let encoded = encode(4_000_000) + encode(-7_500_000) + encode(100_000) + encode(0)
        return RouteGeometry(source: "Test", segments: [RouteGeometry.Segment(encodedPolyline: encoded, precision: 5, pointCount: 2)])
    }

    /// Departs at `start`, calls mid-line half an hour on, arrives an hour after leaving.
    private func trip(
        _ id: String, start: Double = 0, cancelled: Bool = false, position: Bool = false, track: Bool = false
    ) -> TrainTrip {
        TrainTrip(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: id), source: "amtraker", serviceDate: base,
            operatorName: "Amtrak", product: "Test \(id)", headsign: "NTH",
            stopTimes: [
                StopTime(station: station("STH", latitude: 40.0), sequence: 1,
                         scheduledDeparture: minutes(start), expectedDeparture: minutes(start), isCancelled: cancelled),
                StopTime(station: station("MID", latitude: 40.5), sequence: 2, scheduledArrival: minutes(start + 30),
                         scheduledDeparture: minutes(start + 31), expectedArrival: minutes(start + 30),
                         expectedDeparture: minutes(start + 31), isCancelled: cancelled),
                StopTime(station: station("NTH", latitude: 41.0), sequence: 3,
                         scheduledArrival: minutes(start + 60), expectedArrival: minutes(start + 60), isCancelled: cancelled),
            ],
            routeGeometry: track ? Self.straightTrack : nil,
            positions: position ? [VehiclePosition(
                coordinate: GeoCoordinate(latitude: 40.2, longitude: -75.0), source: .real, confidence: 0.9, asOf: minutes(start + 14)
            )] : [],
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: true, granularity: .perStop)
        )
    }

    private func summary(_ id: String, departed minutesAgo: Double, at now: Date, cancelled: Bool = false) -> StopTimeSummary {
        let departure = now.addingTimeInterval(-minutesAgo * 60)
        return StopTimeSummary(
            tripID: RailIdentifier(region: "us", source: "amtraker", nativeID: id), serviceDate: base,
            stopTime: StopTime(station: station("STH", latitude: 40.0), sequence: 1,
                               scheduledDeparture: departure, expectedDeparture: departure, isCancelled: cancelled),
            headsign: "NTH", product: "Test \(id)"
        )
    }

    // MARK: First run

    func testFirstRunAsksOnlyAboutTrainsThatHaveLeftAndAreLikelyStillRunning() {
        let now = minutes(200)
        let board = [
            summary("soon", departed: -10, at: now),      // has not left
            summary("just", departed: 3, at: now),        // still in the station throat
            summary("half", departed: 34, at: now),
            summary("hour", departed: 70, at: now),
            summary("old", departed: 200, at: now),       // long gone
            summary("off", departed: 40, at: now, cancelled: true),
        ]
        let picked = FirstRunTrainPicker.departed(board, at: now).map { $0.tripID.nativeID }
        XCTAssertEqual(picked, ["half", "hour"], "closest to half an hour out first; never a canceled or waiting train")
    }

    func testFirstRunShowsOnlyATrainUnderwayWithTimeToRun() {
        XCTAssertTrue(FirstRunTrainPicker.isShowable(trip("a"), at: minutes(20)))
        XCTAssertFalse(FirstRunTrainPicker.isShowable(trip("a"), at: minutes(-5)), "not before it leaves")
        XCTAssertFalse(FirstRunTrainPicker.isShowable(trip("a"), at: minutes(50)), "not with ten minutes left")
        XCTAssertFalse(FirstRunTrainPicker.isShowable(trip("a"), at: minutes(90)), "not after it arrives")
        XCTAssertFalse(FirstRunTrainPicker.isShowable(trip("a", cancelled: true), at: minutes(20)))
    }

    func testFirstRunPrefersAReportedPositionThenADrawnTrack() {
        let now = minutes(20)
        let plain = trip("plain"), tracked = trip("tracked", track: true), reported = trip("reported", position: true)
        XCTAssertEqual(FirstRunTrainPicker.best([plain, tracked], at: now)?.id, tracked.id)
        XCTAssertEqual(FirstRunTrainPicker.best([tracked, reported, plain], at: now)?.id, reported.id)
        XCTAssertNil(FirstRunTrainPicker.best([trip("late", start: 300)], at: now), "nothing running is no train, not a wrong one")
    }

    func testFuturePositionDoesNotElevateASuggestedTrain() {
        let mapped = trip("mapped", track: true)
        let futureReport = trip("future", start: 8, position: true)
        let now = minutes(18)
        XCTAssertTrue(FirstRunTrainPicker.isShowable(futureReport, at: now))
        XCTAssertEqual(FirstRunTrainPicker.best([mapped, futureReport], at: now)?.id, mapped.id)
    }

    func testFirstRunHubIsTheStationAtTheHubNotANamesake() {
        let hub = FirstRunHub.newYork
        let far = station("NYX", latitude: 43.0, longitude: -76.0)
        let near = station("NYP", latitude: 40.7506, longitude: -73.9935)
        XCTAssertEqual(FirstRunTrainPicker.station(in: [far, near], near: hub)?.id, near.id)
        XCTAssertNil(FirstRunTrainPicker.station(in: [far], near: hub))
    }

    func testFirstRunHubsFollowTheRegionAndAlwaysHaveAFallback() {
        XCTAssertEqual(FirstRunHub.hubs(regionCode: "US").first, .newYork)
        XCTAssertEqual(FirstRunHub.hubs(regionCode: "PT").first?.query, "Lisboa Oriente")
        XCTAssertEqual(FirstRunHub.hubs(regionCode: "DE"), [.berlin, .newYork])
        XCTAssertEqual(FirstRunHub.hubs(regionCode: "JP").count, 2)
        XCTAssertEqual(FirstRunHub.hubs(regionCode: nil).count, 2)
    }

    // MARK: Panel to map

    private let nodes = [
        JourneyMapLink.LineNode(id: "a", x: 100), JourneyMapLink.LineNode(id: "b", x: 200), JourneyMapLink.LineNode(id: "c", x: 300),
    ]

    func testSlidingAlongTheLineGivesTheShareOfTheWayBetweenStops() {
        XCTAssertEqual(JourneyMapLink.focus(at: 150, nodes: nodes), .between("a", "b", t: 0.5))
        XCTAssertEqual(JourneyMapLink.focus(at: 275, nodes: nodes), .between("b", "c", t: 0.75))
    }

    func testSlidingSnapsToAStopAndStaysOnTheLine() {
        XCTAssertEqual(JourneyMapLink.focus(at: 204, nodes: nodes)?.stopID, "b")
        XCTAssertEqual(JourneyMapLink.focus(at: 195, nodes: nodes)?.stopID, "b")
        XCTAssertEqual(JourneyMapLink.focus(at: 20, nodes: nodes)?.stopID, "a", "left of the line is its first stop")
        XCTAssertEqual(JourneyMapLink.focus(at: 900, nodes: nodes)?.stopID, "c", "right of the line is its last stop")
        XCTAssertNil(JourneyMapLink.focus(at: 150, nodes: nodes)?.stopID)
    }

    func testASlideMustStartOnTheLineAndThenKeepsTheDrag() {
        let link = JourneyMapLink()
        link.registerLine(frame: CGRect(x: 90, y: 500, width: 220, height: 60), nodes: nodes)
        XCTAssertFalse(link.scrub(start: CGPoint(x: 150, y: 300), location: CGPoint(x: 170, y: 300)), "a drag elsewhere is the panel's")
        XCTAssertNil(link.focus)
        XCTAssertTrue(link.scrub(start: CGPoint(x: 150, y: 530), location: CGPoint(x: 150, y: 530)))
        XCTAssertTrue(link.scrub(start: CGPoint(x: 150, y: 530), location: CGPoint(x: 250, y: 300)), "once sliding, a wandering finger keeps it")
        XCTAssertEqual(link.focus, .between("b", "c", t: 0.5))
        link.endScrub()
        XCTAssertFalse(link.isScrubbing)
        XCTAssertEqual(link.focus, .between("b", "c", t: 0.5), "the map stays where the finger left it")
        XCTAssertEqual(link.scrubX, 250)
        link.tap(at: CGPoint(x: 110, y: 530))
        XCTAssertEqual(link.focus, .stop("a"))
        XCTAssertNil(link.scrubX, "a chosen stop has no slide mark")
        link.tap(at: CGPoint(x: 150, y: 530))
        XCTAssertEqual(link.focus, .stop("a"), "a tap between stops chooses nothing new")
    }

    func testFocusFollowsTheTrackBetweenStops() throws {
        let train = trip("f", track: true)
        let ids = train.stopTimes.map(\.id)
        let path = RoutePath(coordinates: [
            CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0), CLLocationCoordinate2D(latitude: 41.0, longitude: -75.0),
        ])
        let stop = try XCTUnwrap(JourneyMapFocus.stop(ids[1]).coordinate(in: train, path: path))
        XCTAssertEqual(stop.latitude, 40.5, accuracy: 0.0001)
        let halfway = try XCTUnwrap(JourneyMapFocus.between(ids[0], ids[1], t: 0.5).coordinate(in: train, path: path))
        XCTAssertEqual(halfway.latitude, 40.25, accuracy: 0.01)
        let straight = try XCTUnwrap(JourneyMapFocus.between(ids[1], ids[2], t: 0.5).coordinate(in: train, path: nil))
        XCTAssertEqual(straight.latitude, 40.75, accuracy: 0.0001, "without a track it is the straight line between the stops")
        XCTAssertNil(JourneyMapFocus.stop("missing").coordinate(in: train, path: path))
    }

    // MARK: Status words

    func testStatusNeverMixesHowTheTrainRunsWithWhereTheTimesComeFrom() {
        let underway = TripPresentationStatus(trip: trip("s"), referenceDate: minutes(10))
        XCTAssertEqual(underway.text, "On time")
        XCTAssertTrue(underway.saysHowTheTrainRuns)
        XCTAssertEqual(underway.headline, "On time")
        for word in ["Estimated", "Expected", "Scheduled", "Timetable", "Saved", "Live"] {
            XCTAssertFalse(underway.text.contains(word))
        }
        let ended = TripPresentationStatus(trip: trip("s"), referenceDate: minutes(120))
        XCTAssertEqual(ended.text, "Arrival unconfirmed", "the timetable running out is not a reported arrival")
    }

    // MARK: Confirmed progress

    /// A three-stop journey from 0 to 60 minutes. `reportedThrough` stops carry a passage
    /// observation; `legacyPassed` sets the bare flag with nothing behind it.
    private func evidenceTrip(
        reportedThrough: Int = 0, legacyPassed: Bool = false, position: (latitude: Double, at: Double)? = nil
    ) -> TrainTrip {
        let places = [("STH", 40.0), ("MID", 40.5), ("NTH", 41.0)]
        let times: [(Double?, Double?)] = [(nil, 0), (30, 31), (60, nil)]
        return TrainTrip(
            id: RailIdentifier(region: "eu", source: "transitous", nativeID: "es-1"), source: "transitous", serviceDate: base,
            operatorName: "Renfe", product: "AVE 1", headsign: "NTH",
            stopTimes: places.indices.map { index in
                let reported = index < reportedThrough
                return StopTime(
                    station: station(places[index].0, latitude: places[index].1), sequence: index + 1,
                    scheduledArrival: times[index].0.map(minutes), scheduledDeparture: times[index].1.map(minutes),
                    isPassed: reported || legacyPassed,
                    passageObservedAt: reported ? minutes((times[index].1 ?? times[index].0 ?? 0) + 1) : nil
                )
            },
            routeGeometry: Self.straightTrack,
            positions: position.map {
                [VehiclePosition(coordinate: GeoCoordinate(latitude: $0.latitude, longitude: -75.0), source: .real,
                                 confidence: 0.9, asOf: minutes($0.at))]
            } ?? [],
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: false, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }

    private func progress(_ trip: TrainTrip, at minute: Double) -> RailJourneyProgress {
        RailJourneyProgress(trip: trip, referenceDate: minutes(minute))
    }

    func testATimetableThatHasRunOutClaimsNothing() {
        let stale = evidenceTrip()
        let late = progress(stale, at: 120)
        XCTAssertEqual(late.phase, .ended, "the clock still ends the timetable window")
        XCTAssertFalse(ArrivalEvidence.arrivalIsConfirmed(progress: late))
        XCTAssertTrue(ArrivalEvidence.timetableElapsedUnconfirmed(late))
        for stop in late.stops { XCTAssertFalse(ArrivalEvidence.hasReached(stop, progress: late)) }

        let status = TripPresentationStatus(trip: stale, referenceDate: minutes(120))
        XCTAssertEqual(status.text, "Arrival unconfirmed")
        XCTAssertFalse(status.saysHowTheTrainRuns)
        XCTAssertNil(LiveLineTicketPresentation.stopsLeft(in: late), "no zero stops left from the clock")
        let card = ActiveTripCardPresentation(trip: stale, referenceDate: minutes(120), lastSuccessfulCheck: minutes(119))
        XCTAssertEqual(card.nextStopValue, "Arrival unconfirmed", "a successful fetch is not an arrival")

        let line = RouteLineSummary(stops: late.stops, focusStopID: nil, phase: .ended, referenceDate: minutes(120),
                                    showsLiveMarker: true, confirmedPassedStopIDs: late.evidence.confirmedPassedStopIDs,
                                    isArrivalConfirmed: late.evidence.isArrivalConfirmed)
        XCTAssertFalse(line.nodes.contains { $0.state == .passed }, "no filled dots from the clock")
        XCTAssertNil(line.liveMarkerFraction)
    }

    func testLegacyPassedFlagsWithoutAnObservationAreNotReached() {
        let legacy = evidenceTrip(legacyPassed: true)
        let now = progress(legacy, at: 120)
        XCTAssertFalse(ArrivalEvidence.arrivalIsConfirmed(progress: now))
        XCTAssertFalse(ArrivalEvidence.hasReached(now.stops[1], progress: now))
        XCTAssertEqual(TripPresentationStatus(trip: legacy, referenceDate: minutes(120)).text, "Arrival unconfirmed")
        XCTAssertNotNil(StopWakePlan(trip: legacy, stopID: legacy.stopTimes[2].station.id.rawValue, leadMinutes: 10),
                        "a bare passed flag does not put the rider's stop behind the train")
    }

    func testAFreshTrainPositionBehindTheClockHoldsProgressBack() {
        // The timetable says the train is past the middle stop; it is reported well short of it.
        let behind = evidenceTrip(position: (latitude: 40.2, at: 44))
        let now = progress(behind, at: 45)
        XCTAssertFalse(ArrivalEvidence.hasReached(now.stops[1], progress: now))
        let line = RouteLineSummary(stops: now.stops, focusStopID: now.focusStop?.id, phase: now.phase,
                                    referenceDate: minutes(45), showsLiveMarker: true, confirmedPassedStopIDs: now.evidence.confirmedPassedStopIDs)
        XCTAssertNotEqual(line.nodes[1].state, .passed, "the middle stop is not filled while the train is short of it")
    }

    func testReportedPassageFillsOnlyWhatWasReported() {
        let underway = evidenceTrip(reportedThrough: 2)
        let now = progress(underway, at: 45)
        XCTAssertTrue(ArrivalEvidence.hasReached(now.stops[0], progress: now))
        XCTAssertTrue(ArrivalEvidence.hasReached(now.stops[1], progress: now))
        XCTAssertFalse(ArrivalEvidence.hasReached(now.stops[2], progress: now))
        XCTAssertFalse(ArrivalEvidence.arrivalIsConfirmed(progress: now))
        let line = RouteLineSummary(stops: now.stops, focusStopID: now.focusStop?.id, phase: now.phase,
                                    referenceDate: minutes(45), showsLiveMarker: false, confirmedPassedStopIDs: now.evidence.confirmedPassedStopIDs)
        XCTAssertEqual(line.nodes.map(\.state), [.passed, .passed, .next])
    }

    func testAReportedArrivalAtTheRidersStopCompletesTheJourney() {
        let arrived = evidenceTrip(reportedThrough: 3)
        let now = progress(arrived, at: 62)
        XCTAssertEqual(now.phase, .ended)
        XCTAssertTrue(ArrivalEvidence.arrivalIsConfirmed(progress: now))
        XCTAssertFalse(ArrivalEvidence.timetableElapsedUnconfirmed(now))
        XCTAssertEqual(TripPresentationStatus(trip: arrived, referenceDate: minutes(62)).text, "Arrived")
        XCTAssertEqual(LiveLineTicketPresentation.stopsLeft(in: now), 0)
        XCTAssertNil(StopWakePlan(trip: arrived, stopID: arrived.stopTimes[2].station.id.rawValue, leadMinutes: 10),
                     "a stop the train is reported at has no alert left to set")

        // Getting off at the middle stop: confirmed there, whatever the train does afterwards.
        let alighted = RailJourneyProgress(
            trip: arrived, referenceDate: minutes(62),
            boardingStationID: arrived.stopTimes[0].station.id, alightingStationID: arrived.stopTimes[1].station.id
        )
        XCTAssertEqual(alighted.stops.count, 2)
        XCTAssertTrue(ArrivalEvidence.arrivalIsConfirmed(progress: alighted))
    }

    func testAStubKeptOnTheTimetableIsReplacedWhenTheArrivalIsReported() throws {
        let log = TravelLog(fileURL: nil)
        let train = trip("log")
        let unconfirmed = try XCTUnwrap(TravelLogEntry(trip: train, stops: train.stopTimes, arrivalConfirmed: false))
        let confirmed = try XCTUnwrap(TravelLogEntry(trip: train, stops: train.stopTimes, arrivalConfirmed: true))
        XCTAssertTrue(log.record(unconfirmed))
        XCTAssertFalse(log.entries[0].isArrivalConfirmed)
        XCTAssertFalse(log.record(unconfirmed), "the same stub is kept once")
        XCTAssertTrue(log.record(confirmed), "a reported arrival replaces the timetable stub")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertTrue(log.entries[0].isArrivalConfirmed)
        XCTAssertFalse(log.record(unconfirmed), "and is never downgraded")
    }

    func testStubsKeptBeforeEvidenceWasRecordedAreNotProofOfArrival() throws {
        let old = try XCTUnwrap(TravelLogEntry.previewSamples.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["arrivalReported"] = nil
        let decoded = try JSONDecoder().decode(TravelLogEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.isArrivalConfirmed, "a stub kept by the clock stays unconfirmed")
    }

    // MARK: Wake alert: the latest command wins

    /// Alerts whose permission prompt is answered only when the test says so.
    private func gatedAlerts() -> (alerts: StopWakeAlerts, added: () -> [String], approve: () -> Void) {
        let suite = "wake-test-\(UUID().uuidString)"
        let alerts = StopWakeAlerts(defaults: UserDefaults(suiteName: suite)!)
        final class Box: @unchecked Sendable {
            var waiting: [CheckedContinuation<Void, Never>] = []
            var added: [String] = []
        }
        let box = Box()
        alerts.requestPermissions = {
            await withCheckedContinuation { box.waiting.append($0) }
            return (notifications: true, location: false)
        }
        alerts.addRequest = { box.added.append($0.identifier) }
        alerts.removeRequests = { ids in box.added.removeAll { ids.contains($0) } }
        return (alerts, { box.added }, { box.waiting.forEach { $0.resume() }; box.waiting = [] })
    }

    private func upcomingTrip() -> TrainTrip {
        // Leaves in an hour, so its stops are ahead of the real clock the alerts read.
        let start = Date.now.timeIntervalSince(base) / 60 + 60
        return trip("wake", start: start)
    }

    func testADisarmWhileTheArmWaitsOnAPromptIsNotOverwrittenByALateApproval() async {
        let (alerts, added, approve) = gatedAlerts()
        let train = upcomingTrip()
        let stopID = train.stopTimes[2].station.id.rawValue
        let arming = Task { await alerts.arm(trip: train, stopID: stopID, productName: "Test", leadMinutes: 10) }
        await Task.yield()
        alerts.disarm(tripID: train.id)   // the rider switched it off while the prompt was up
        approve()                          // and then allowed notifications
        let result = await arming.value
        XCTAssertEqual(result, .superseded)
        XCTAssertNil(alerts.alert(for: train.id), "the late approval stores no alert")
        XCTAssertTrue(added().isEmpty, "and schedules nothing")
    }

    func testTheLaterOfTwoArmsIsTheOneKept() async {
        let (alerts, added, approve) = gatedAlerts()
        let train = upcomingTrip()
        let stopID = train.stopTimes[2].station.id.rawValue
        let first = Task { await alerts.arm(trip: train, stopID: stopID, productName: "Test", leadMinutes: 5) }
        await Task.yield()
        let second = Task { await alerts.arm(trip: train, stopID: stopID, productName: "Test", leadMinutes: 15) }
        await Task.yield()
        approve()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.superseded, .armed])
        XCTAssertEqual(alerts.alert(for: train.id)?.leadMinutes, 15)
        XCTAssertEqual(Set(added()).count, added().count, "each alert is scheduled once")
        XCTAssertFalse(added().isEmpty)
    }

    func testAnArmThatIsNotOvertakenStillArms() async {
        let (alerts, added, approve) = gatedAlerts()
        let train = upcomingTrip()
        let arming = Task { await alerts.arm(trip: train, stopID: train.stopTimes[2].station.id.rawValue, productName: "Test", leadMinutes: 10) }
        await Task.yield()
        approve()
        let result = await arming.value
        XCTAssertEqual(result, .armed)
        XCTAssertEqual(alerts.alert(for: train.id)?.leadMinutes, 10)
        XCTAssertEqual(added().count, 2, "the approach alert and the last call")
        alerts.disarm(tripID: train.id)
        XCTAssertTrue(added().isEmpty)
    }

    // MARK: Share picture

    func testRiddenLineKeepsItsProportionsInsideTheBox() {
        let points = [
            TravelLogEntry.Point(latitude: 40, longitude: -75), TravelLogEntry.Point(latitude: 40, longitude: -73),
            TravelLogEntry.Point(latitude: 41, longitude: -73),
        ]
        let box = CGRect(x: 0, y: 0, width: 300, height: 100)
        let fitted = RiddenLine.fit(points, in: box)
        XCTAssertEqual(fitted.count, 3)
        for point in fitted { XCTAssertTrue(box.contains(point)) }
        XCTAssertEqual(fitted[0].y, fitted[1].y, accuracy: 0.001, "east-west stays level")
        XCTAssertLessThan(fitted[2].y, fitted[1].y, "north is up")
        XCTAssertTrue(RiddenLine.fit([points[0]], in: box).isEmpty)
    }

    func testShareCardRendersAsAFourByFivePicture() throws {
        let entry = try XCTUnwrap(TravelLogEntry.previewSamples.first)
        let item = try XCTUnwrap(TravelLogShareItem(entry: entry))
        XCTAssertEqual(item.image.size.width * item.image.scale, 1080, accuracy: 1)
        XCTAssertEqual(item.image.size.height * item.image.scale, 1350, accuracy: 1)
        XCTAssertTrue(item.title.contains(entry.originName))
        // Kept beside the test run so the picture can be looked at.
        let url = URL.temporaryDirectory.appending(path: "travel-log-share-card.png")
        try item.image.pngData()?.write(to: url)
        print("SHARE_CARD_PATH \(url.path)")
    }
}
