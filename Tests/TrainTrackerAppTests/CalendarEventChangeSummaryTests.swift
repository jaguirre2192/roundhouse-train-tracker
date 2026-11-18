import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class CalendarEventChangeSummaryTests: XCTestCase {
    func testStructuredDifferencesRetainExplicitPreviousAndCurrentValues() {
        let candidate = candidate(origin: "Washington", destination: "Philadelphia", train: "179", departure: 1_800_086_400, zone: "Europe/London", allDay: true)
        let summary = summary(candidate, details: details())

        XCTAssertEqual(summary.changes.map(\.field), [.origin, .destination, .trainNumber, .departure, .timeZone, .calendarTiming])
        XCTAssertEqual(summary.changes.first?.previouslyImported, .text("Boston"))
        XCTAssertEqual(summary.changes.first?.calendarEvent, .text("Washington"))
        XCTAssertEqual(summary.changes.last?.previouslyImported, .allDay(false))
        XCTAssertEqual(summary.changes.last?.calendarEvent, .allDay(true))
        XCTAssertNil(summary.explanation)
    }

    func testMissingCurrentExtractionDoesNotInventReplacementRouteOrNumber() {
        let summary = summary(candidate(origin: nil, destination: nil, train: nil), details: details())
        XCTAssertEqual(summary.changes.map(\.field), [.origin, .destination, .trainNumber])
        XCTAssertTrue(summary.changes.allSatisfy { $0.calendarEvent == .text(nil) })
    }

    func testLegacyImportExplainsUnavailableHistoryWithoutInventingDeltas() {
        let candidate = candidate(origin: "Washington")
        let source = CalendarJourneySource(eventKey: candidate.id, revision: "old")
        let summary = CalendarEventChangeSummary(candidate: candidate, previousSource: source)
        XCTAssertTrue(summary.changes.isEmpty)
        XCTAssertEqual(summary.explanation, .previousDetailsUnavailable)
    }

    func testChangedHiddenMetadataProducesGenericExplanation() {
        let original = candidate(notes: "SYNTHETIC ORIGINAL NOTES")
        let changed = candidate(notes: "SYNTHETIC UPDATED NOTES")
        let source = CalendarJourneySource(
            eventKey: original.id, revision: original.snapshot.importSource.revision, details: details()
        )
        let summary = CalendarEventChangeSummary(candidate: changed, previousSource: source)

        XCTAssertNotEqual(original.snapshot.importSource.revision, changed.snapshot.importSource.revision)
        XCTAssertTrue(summary.changes.isEmpty)
        XCTAssertEqual(summary.explanation, .unrecordedChange)
        XCTAssertFalse(summary.explanation?.message.contains("SYNTHETIC") ?? true)
    }

    func testUnchangedEventDoesNotMisrepresentPriorManualCorrectionAsCalendarEdit() {
        let candidate = candidate(origin: "Calendar guess")
        let source = CalendarJourneySource(
            eventKey: candidate.id, revision: candidate.snapshot.importSource.revision, details: details()
        )
        let summary = CalendarEventChangeSummary(candidate: candidate, previousSource: source)
        XCTAssertTrue(summary.changes.isEmpty)
        XCTAssertEqual(summary.explanation, .unchanged)
    }

    func testDifferentOccurrenceCannotSupplyBeforeValues() {
        let source = CalendarJourneySource(eventKey: "another-occurrence", revision: "old", details: details())
        let summary = CalendarEventChangeSummary(candidate: candidate(), previousSource: source)
        XCTAssertTrue(summary.changes.isEmpty)
        XCTAssertEqual(summary.explanation, .differentEvent)
    }

    func testAllDayMidnightDoesNotReplaceConfirmedTimeInComparison() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2032, month: 2, day: 10)))
        let confirmed = details(departure: midnight.addingTimeInterval(9 * 3_600).timeIntervalSince1970, allDay: true)
        let sameDay = candidate(departure: midnight.timeIntervalSince1970, allDay: true)
        let nextDay = candidate(departure: midnight.addingTimeInterval(86_400).timeIntervalSince1970, allDay: true)

        XCTAssertTrue(summary(sameDay, details: confirmed).changes.isEmpty)
        let moved = summary(nextDay, details: confirmed)
        XCTAssertEqual(moved.changes.map(\.field), [.departure])
        XCTAssertEqual(moved.changes.first?.previouslyImported, .departure(confirmed.departureDate, timeZoneIdentifier: "America/New_York", includesTime: true))
        XCTAssertEqual(moved.changes.first?.calendarEvent, .departure(nextDay.snapshot.startDate, timeZoneIdentifier: "America/New_York", includesTime: false))
    }

    func testTimeZoneChangeAtSameInstantIsExplicit() {
        let summary = summary(candidate(zone: "America/Los_Angeles"), details: details())
        XCTAssertEqual(summary.changes.map(\.field), [.timeZone])
        XCTAssertEqual(summary.changes.first?.previouslyImported, .timeZone("America/New_York"))
        XCTAssertEqual(summary.changes.first?.calendarEvent, .timeZone("America/Los_Angeles"))
    }

    func testCaseWhitespaceAndSubMinuteDifferencesAreNotVisualDeltas() {
        let candidate = candidate(origin: " BOSTON ", destination: "New   York", train: " t176 ", departure: 1_800_000_010)
        let reviewed = CalendarJourneyDetails(
            originName: "Boston", destinationName: "New York", trainNumber: "T176",
            departureDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/New_York", isAllDay: false
        )
        let summary = summary(candidate, details: reviewed)
        XCTAssertTrue(summary.changes.isEmpty)
        XCTAssertEqual(summary.explanation, .unrecordedChange)
    }

    func testFloatingDepartureComparesStationClockToCalendarClockWhenTravelling() throws {
        let clock = TicketWallClock(year: 2027, month: 1, day: 20, hour: 23, minute: 15)
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let boarding = try XCTUnwrap(clock.exactTime(in: ny))
        let eventDate = try XCTUnwrap(clock.exactTime(in: NSTimeZone.default))
        let reviewed = CalendarJourneyDetails(
            originName: "Boston", destinationName: "New York", trainNumber: "176",
            departureDate: boarding, timeZoneIdentifier: nil, isAllDay: false, boardingTimeZoneIdentifier: ny.identifier
        )
        let same = candidate(departure: eventDate.timeIntervalSince1970, zone: nil)
        XCTAssertTrue(summary(same, details: reviewed).changes.isEmpty)
        let delayed = candidate(departure: eventDate.timeIntervalSince1970 + 900, zone: nil)
        XCTAssertEqual(summary(delayed, details: reviewed).changes.map(\.field), [.departure])
    }

    private func summary(_ candidate: CalendarJourneyCandidate, details: CalendarJourneyDetails) -> CalendarEventChangeSummary {
        CalendarEventChangeSummary(
            candidate: candidate,
            previousSource: CalendarJourneySource(eventKey: candidate.id, revision: "old", details: details)
        )
    }

    private func details(departure: TimeInterval = 1_800_000_000, allDay: Bool = false) -> CalendarJourneyDetails {
        CalendarJourneyDetails(
            originName: "Boston", destinationName: "New York", trainNumber: "176",
            departureDate: Date(timeIntervalSince1970: departure), timeZoneIdentifier: "America/New_York", isAllDay: allDay
        )
    }

    private func candidate(
        origin: String? = "Boston", destination: String? = "New York", train: String? = "176",
        departure: TimeInterval = 1_800_000_000, zone: String? = "America/New_York",
        allDay: Bool = false, notes: String? = nil
    ) -> CalendarJourneyCandidate {
        CalendarJourneyCandidate(
            snapshot: CalendarEventSnapshot(
                eventIdentifier: "synthetic-event", calendarTitle: "Synthetic calendar", title: "Amtrak booking",
                notes: notes, location: nil, startDate: Date(timeIntervalSince1970: departure),
                endDate: Date(timeIntervalSince1970: departure + 3_600), isAllDay: allDay, timeZoneIdentifier: zone
            ),
            classification: CalendarJourneyClassification(
                confidence: .high, evidence: [], originGuess: origin, destinationGuess: destination, trainNumberGuess: train
            )
        )
    }
}
