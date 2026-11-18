import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyTimePresentationTests: XCTestCase {
    func testFormatsEndpointTimesInTheirLocalTimeZonesAcrossDST() {
        let losAngeles = place(
            id: "us:la",
            name: "Los Angeles Union Station",
            timeZone: "America/Los_Angeles"
        )
        let newYork = place(
            id: "us:ny",
            name: "New York Penn Station",
            timeZone: "America/New_York"
        )
        let option = option(
            start: date("2026-03-08T09:30:00Z"),
            end: date("2026-03-08T15:30:00Z"),
            origin: losAngeles,
            destination: newYork
        )

        let presentation = JourneyOptionPresentation(option: option)

        XCTAssertEqual(presentation.time.departure, "1:30 AM")
        XCTAssertEqual(presentation.time.arrival, "11:30 AM")
        XCTAssertNil(presentation.time.arrivalDayContext)
        XCTAssertEqual(presentation.originStation, "Los Angeles Union Station")
        XCTAssertEqual(presentation.destinationStation, "New York Penn Station")
    }

    func testUsesPlusOneForTheNextLocalCalendarDay() throws {
        let option = try fixturePage().options[1]

        let presentation = JourneyOptionPresentation(option: option)

        XCTAssertEqual(presentation.time.departure, "9:55 PM")
        XCTAssertEqual(presentation.time.arrival, "8:19 AM")
        XCTAssertEqual(presentation.time.arrivalDayContext, "+1")
        XCTAssertEqual(presentation.time.duration, "10h 24m")
        XCTAssertEqual(presentation.changes, "1 change")
    }

    func testUsesAnExplicitDateForCrossingsLongerThanOneDay() {
        let option = option(
            start: date("2026-07-24T06:00:00Z"),
            end: date("2026-07-26T06:00:00Z"),
            origin: place(id: "fr:paris", name: "Paris Gare de l'Est", timeZone: "Europe/Paris"),
            destination: place(id: "jp:tokyo", name: "Tokyo Station", timeZone: "Asia/Tokyo")
        )

        let presentation = JourneyOptionPresentation(option: option)

        XCTAssertEqual(presentation.time.arrivalDayContext, "Sun, Jul 26")
        XCTAssertEqual(presentation.time.duration, "48h")
    }

    func testFormatsDirectAndPluralChanges() {
        let direct = JourneyOptionPresentation(option: option(transferCount: 0))
        let twoChanges = JourneyOptionPresentation(option: option(transferCount: 2))

        XCTAssertEqual(direct.changes, "Direct")
        XCTAssertEqual(twoChanges.changes, "2 changes")
    }

    func testShowsOnlySuppliedPlatformsAndCancellationStatus() throws {
        let direct = JourneyOptionPresentation(option: try fixturePage().options[0])
        let cancelled = JourneyOptionPresentation(option: try fixturePage().options[1])
        let noPlatform = JourneyOptionPresentation(option: option())

        XCTAssertEqual(direct.departurePlatform, "Platform 8")
        XCTAssertEqual(direct.arrivalPlatform, "Platform 15b")
        XCTAssertEqual(direct.status, "Live times")
        XCTAssertEqual(cancelled.status, "Canceled")
        XCTAssertNil(cancelled.arrivalPlatform)
        XCTAssertNil(noPlatform.departurePlatform)
        XCTAssertNil(noPlatform.arrivalPlatform)
        XCTAssertNil(noPlatform.status)
    }

    func testPresentsStationsTrainIdentityWarningsBadgesAndTrackability() throws {
        let presentation = JourneyOptionPresentation(option: try fixturePage().options[1])

        XCTAssertEqual(presentation.originStation, "Paris Gare de l'Est")
        XCTAssertEqual(presentation.destinationStation, "Wien Hauptbahnhof")
        XCTAssertEqual(presentation.trainIdentities, ["SNCF · TGV 9579", "ÖBB · Nightjet 237"])
        XCTAssertEqual(presentation.transferWarning, "Station change at Stuttgart Hbf")
        XCTAssertEqual(presentation.trackability, "1 of 2 trains trackable")
        XCTAssertTrue(presentation.badges.isEmpty)
        XCTAssertNil(presentation.recommendationBadge)

        let direct = JourneyOptionPresentation(option: try fixturePage().options[0])
        XCTAssertEqual(direct.badges, ["Direct", "Fastest", "Fewest changes"])
        XCTAssertEqual(direct.trainIdentities, ["Eurostar 9315"])
        XCTAssertEqual(direct.recommendationBadge, "Fastest")
        XCTAssertEqual(direct.trackability, "Tracking available")
    }

    func testVoiceOverPartsHaveDeterministicRequiredOrder() throws {
        let presentation = JourneyOptionPresentation(option: try fixturePage().options[1])

        XCTAssertEqual(
            presentation.accessibilityParts.map(\.kind),
            [.departure, .arrival, .duration, .changes, .status, .trackability]
        )
        XCTAssertEqual(presentation.accessibilityParts[0].value, "Departs 9:55 PM from Paris Gare de l'Est")
        XCTAssertEqual(presentation.accessibilityParts[1].value, "Arrives 8:19 AM +1 at Wien Hauptbahnhof")
        XCTAssertEqual(presentation.accessibilityParts[4].value, "Canceled")
        XCTAssertEqual(presentation.accessibilityParts[5].value, "1 of 2 trains trackable")
        XCTAssertEqual(
            presentation.accessibilityLabel,
            presentation.accessibilityParts.map(\.value).joined(separator: ", ")
        )
    }

    func testVoiceOverOmitsOperationalStatusWhenNoneIsSupplied() {
        let presentation = JourneyOptionPresentation(option: option())

        XCTAssertEqual(
            presentation.accessibilityParts.map(\.kind),
            [.departure, .arrival, .duration, .changes, .trackability]
        )
        XCTAssertFalse(presentation.accessibilityLabel.contains("Schedule only"))
    }

    func testDetailPresentationPreservesEveryCallAndExplicitUntrackableReason() throws {
        let option = try fixturePage().options[1]

        let details = JourneySegmentPresentation.makeAll(from: option)

        XCTAssertEqual(details.map(\.id), option.segments.map(\.id))
        XCTAssertEqual(details[0].calls.map(\.station), ["Paris Gare de l'Est", "Stuttgart Hbf"])
        XCTAssertEqual(details[1].warning, "Station change required")
        XCTAssertEqual(details[1].distance, "450 m")
        XCTAssertEqual(details[2].calls.map(\.station), ["Stuttgart Hbf", "Wien Hauptbahnhof"])
        XCTAssertEqual(details[2].trackability, "Not trackable: No stable train identity")
    }

    func testDetailPresentationDistinguishesScheduledAndExpectedCallTimes() throws {
        let option = try fixturePage().options[0]

        let calls = try XCTUnwrap(JourneySegmentPresentation.makeAll(from: option).first).calls

        XCTAssertEqual(calls[0].scheduledTime, "8:25 AM")
        XCTAssertEqual(calls[0].expectedTime, "8:28 AM")
        XCTAssertEqual(calls[0].displayTime, "8:28 AM")
        XCTAssertTrue(calls[0].hasTimingUpdate)
        XCTAssertEqual(calls[1].scheduledTime, "9:53 AM")
        XCTAssertEqual(calls[1].expectedTime, "9:56 AM")
        XCTAssertEqual(calls[2].scheduledTime, "12:14 PM")
        XCTAssertEqual(calls[2].expectedTime, "12:17 PM")
    }

    private func fixturePage() throws -> JourneySearchPage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "search-page",
            withExtension: "json"
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter().date(from: value) { return date }
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.calendar = Calendar(identifier: .gregorian)
            day.timeZone = TimeZone(secondsFromGMT: 0)
            day.dateFormat = "yyyy-MM-dd"
            return try XCTUnwrap(day.date(from: value))
        }
        return try decoder.decode(JourneySearchPage.self, from: Data(contentsOf: url))
    }

    private func option(
        start requestedStart: Date? = nil,
        end requestedEnd: Date? = nil,
        origin requestedOrigin: RailPlace? = nil,
        destination requestedDestination: RailPlace? = nil,
        transferCount: Int = 0
    ) -> JourneyOption {
        let start = requestedStart ?? date("2026-07-24T08:00:00Z")
        let end = requestedEnd ?? date("2026-07-24T10:00:00Z")
        let origin = requestedOrigin
            ?? place(id: "fr:paris", name: "Paris Gare du Nord", timeZone: "Europe/Paris")
        let destination = requestedDestination
            ?? place(id: "nl:amsterdam", name: "Amsterdam Centraal", timeZone: "Europe/Amsterdam")
        let rail = RailJourneySegment(
            id: "rail",
            tripID: RailIdentifier(rawValue: "fixture:rail"),
            serviceDate: start,
            operatorName: "Example Rail",
            product: "Intercity",
            trainNumber: "42",
            trainName: nil,
            from: call(place: origin, departure: start),
            to: call(place: destination, arrival: end),
            intermediateCalls: [],
            isCancelled: false,
            isRealtime: false,
            isTrackable: true,
            untrackableReason: nil
        )
        return JourneyOption(
            id: "option-\(transferCount)",
            fingerprint: "fingerprint-\(transferCount)",
            startTime: start,
            endTime: end,
            duration: end.timeIntervalSince(start),
            transferCount: transferCount,
            segments: [.rail(rail)],
            badges: transferCount == 0 ? [.direct] : [],
            trackability: JourneyTrackability(trackableRailSegments: 1, totalRailSegments: 1),
            realtimeFreshness: nil,
            attributions: ["Fixture"],
            trackingToken: "signed.fixture"
        )
    }

    private func call(place: RailPlace, departure: Date? = nil, arrival: Date? = nil) -> JourneyCall {
        JourneyCall(
            place: place,
            city: nil,
            scheduledArrival: arrival,
            scheduledDeparture: departure,
            expectedArrival: nil,
            expectedDeparture: nil,
            plannedPlatform: nil,
            expectedPlatform: nil,
            isCancelled: false
        )
    }

    private func place(id: String, name: String, timeZone: String) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: id),
            kind: .station,
            displayName: name,
            context: "Fixture",
            countryCode: "XX",
            timeZoneIdentifier: timeZone,
            location: GeoCoordinate(latitude: 0, longitude: 0),
            eligibleModes: ["longDistanceRail"],
            attributions: ["Fixture"]
        )
    }

    private func date(_ value: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            preconditionFailure("Invalid date fixture: \(value)")
        }
        return date
    }
}


final class StationBoardTimePresentationTests: XCTestCase {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let paris = TimeZone(identifier: "Europe/Paris")!
    // 2026-07-24 01:30 in Berlin is still 2026-07-23 in New York.
    private let instant = ISO8601DateFormatter().date(from: "2026-07-23T23:30:00Z")!

    func testTodayBoundaryFollowsTheStationsZone() {
        let presentation = StationBoardTimePresentation(timeZone: berlin, deviceTimeZone: newYork)
        let range = presentation.selectableRange(from: instant)
        XCTAssertEqual(range.lowerBound, ISO8601DateFormatter().date(from: "2026-07-23T22:00:00Z"))
    }

    func testTimesUseTheStationsClock() {
        let presentation = StationBoardTimePresentation(
            timeZone: berlin, deviceTimeZone: newYork, locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(presentation.time(instant).replacingOccurrences(of: "\u{202F}", with: " "), "1:30 AM")
    }

    func testZoneAbbreviationOnlyWhenTheClockDiffers() {
        XCTAssertNotNil(StationBoardTimePresentation(timeZone: berlin, deviceTimeZone: newYork).zoneAbbreviation(at: instant))
        XCTAssertNil(StationBoardTimePresentation(timeZone: berlin, deviceTimeZone: paris).zoneAbbreviation(at: instant))
        XCTAssertNil(StationBoardTimePresentation(timeZone: berlin, deviceTimeZone: berlin).zoneAbbreviation(at: instant))
    }

    func testOnlyTheLatestStationSearchMayPublish() {
        var gate = LatestRequestGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.isLatest(first))
        XCTAssertTrue(gate.isLatest(second))
    }

    func testMyTripsFreshnessLineReadsAsAStableTimestamp() {
        XCTAssertEqual(MyTripsFreshnessPresentation.text(lastUpdated: nil), JourneySearchCopy.Plan.notCheckedYet)
        XCTAssertEqual(
            MyTripsFreshnessPresentation.text(lastUpdated: nil, isRefreshing: true),
            JourneySearchCopy.Plan.checkingLiveData
        )
        let text = MyTripsFreshnessPresentation.text(
            lastUpdated: instant, timeZone: berlin, locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(text.replacingOccurrences(of: "\u{202F}", with: " "), "Train details updated 1:30 AM")
    }
}
