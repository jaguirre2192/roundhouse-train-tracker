import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class CalendarImportIdentityTests: XCTestCase {
    func testEditingEventChangesRevisionButKeepsImportIdentity() {
        let original = snapshot()
        let edited = snapshot(title: "Amtrak 179: Boston → New York", start: 1_800_000_000)
        XCTAssertEqual(original.importSource.eventKey, edited.importSource.eventKey)
        XCTAssertNotEqual(original.importSource.revision, edited.importSource.revision)
        XCTAssertEqual(original.importSource.eventKey.count, 64)
        XCTAssertFalse(original.importSource.eventKey.contains(original.eventIdentifier))
    }

    func testRecurringOccurrencesHaveSeparateIdentityAndMovedOccurrenceKeepsIdentity() {
        let first = snapshot(occurrence: Date(timeIntervalSince1970: 1_700_000_000))
        let second = snapshot(occurrence: Date(timeIntervalSince1970: 1_700_086_400))
        let moved = snapshot(start: 1_800_000_000, occurrence: first.occurrenceDate)
        XCTAssertNotEqual(first.importSource.eventKey, second.importSource.eventKey)
        XCTAssertEqual(first.importSource.eventKey, moved.importSource.eventKey)
        XCTAssertNotEqual(first.importSource.revision, moved.importSource.revision)
    }

    func testCancellationAndTimeZoneChangesRequireReview() {
        let original = snapshot()
        XCTAssertNotEqual(original.importSource.revision, snapshot(cancelled: true).importSource.revision)
        XCTAssertNotEqual(original.importSource.revision, snapshot(timeZone: "Europe/Paris").importSource.revision)
    }

    func testAllDayCandidateRequiresExplicitTimeAndCarriesTimeZoneAndIdentity() throws {
        let event = snapshot(allDay: true)
        let candidate = CalendarJourneyCandidate(
            snapshot: event, classification: try XCTUnwrap(CalendarJourneyClassifier.classify(event))
        )
        let suggestion = candidate.routeSuggestion
        XCTAssertTrue(suggestion.requiresDepartureTime)
        XCTAssertEqual(suggestion.departureTimeZoneIdentifier, "America/New_York")
        XCTAssertEqual(suggestion.calendarSource, event.importSource)
        let request = suggestion.journeySearchRequest(
            origin: "Boston", destination: "New York", trainNumber: "176", departureDate: event.startDate
        )
        XCTAssertEqual(request.calendarSource?.eventKey, event.importSource.eventKey)
        XCTAssertEqual(request.calendarSource?.revision, event.importSource.revision)
        XCTAssertEqual(request.calendarSource?.details?.originName, "Boston")
        XCTAssertEqual(request.calendarSource?.details?.destinationName, "New York")
        XCTAssertEqual(request.calendarSource?.details?.trainNumber, "176")
        XCTAssertEqual(request.calendarSource?.details?.departureDate, event.startDate)
        XCTAssertEqual(request.calendarSource?.details?.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(request.calendarSource?.details?.isAllDay, true)
        XCTAssertFalse(TicketRouteReviewPolicy.canConfirm(
            origin: "Boston", destination: "New York", requiresDepartureTime: true, departureTimeConfirmed: false
        ))
        XCTAssertTrue(TicketRouteReviewPolicy.canConfirm(
            origin: "Boston", destination: "New York", requiresDepartureTime: true, departureTimeConfirmed: true
        ))
    }

    func testReviewRejectsBlankAndSameEndpoints() {
        for route in [(" ", "Paris"), ("Paris", "\n"), (" Paris ", "paris")] {
            XCTAssertFalse(TicketRouteReviewPolicy.canConfirm(
                origin: route.0, destination: route.1, requiresDepartureTime: false, departureTimeConfirmed: true
            ))
        }
    }

    private func snapshot(
        title: String = "Amtrak 176: Boston → New York",
        start: TimeInterval = 1_700_000_000,
        allDay: Bool = false,
        timeZone: String = "America/New_York",
        cancelled: Bool = false,
        occurrence: Date? = nil
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: "private-event-id", calendarTitle: "Travel", title: title,
            notes: nil, location: nil, startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: start + 3600), isAllDay: allDay,
            timeZoneIdentifier: timeZone, isCancelled: cancelled, occurrenceDate: occurrence,
            isRecurring: occurrence != nil
        )
    }
}
