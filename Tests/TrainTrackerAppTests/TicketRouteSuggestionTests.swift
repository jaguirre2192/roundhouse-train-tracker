import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class TicketRouteSuggestionTests: XCTestCase {
    func testJourneySearchRequestUsesISO8601DepartureAndTrimmedTrainNumber() {
        let suggestion = TicketRouteSuggestion(sourceDescription: "Calendar")
        let departure = Date(timeIntervalSince1970: 1_700_000_000)

        let request = suggestion.journeySearchRequest(
            origin: "Boston",
            destination: "New York",
            trainNumber: "  2151  ",
            departureDate: departure
        )

        XCTAssertEqual(request.originName, "Boston")
        XCTAssertEqual(request.destinationName, "New York")
        XCTAssertEqual(request.trainNumber, "2151")
        XCTAssertEqual(ISO8601DateFormatter().date(from: request.departureTime ?? ""), departure)
    }

    func testJourneySearchRequestTreatsBlankTrainNumberAsNil() {
        let suggestion = TicketRouteSuggestion(sourceDescription: "Calendar")

        let request = suggestion.journeySearchRequest(
            origin: "Boston",
            destination: "New York",
            trainNumber: "   ",
            departureDate: .now
        )

        XCTAssertNil(request.trainNumber)
    }

    func testCalendarCandidateProducesMatchingSuggestion() {
        let departure = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = CalendarEventSnapshot(
            eventIdentifier: "event-1",
            calendarTitle: "Personal",
            title: "Amtrak to Washington",
            notes: nil,
            location: nil,
            startDate: departure,
            endDate: departure.addingTimeInterval(3600),
            isAllDay: false
        )
        let classification = CalendarJourneyClassification(
            confidence: .high,
            evidence: ["Mentions Amtrak"],
            originGuess: "Boston",
            destinationGuess: "Washington",
            trainNumberGuess: nil
        )
        let candidate = CalendarJourneyCandidate(snapshot: snapshot, classification: classification)

        let suggestion = candidate.routeSuggestion

        XCTAssertEqual(suggestion.originGuess, "Boston")
        XCTAssertEqual(suggestion.destinationGuess, "Washington")
        XCTAssertEqual(suggestion.departureDate, departure)
        XCTAssertEqual(suggestion.confidence, .high)
        XCTAssertEqual(suggestion.sourceDescription, "Personal")
    }

    func testCalendarRequestPersistsConfirmedFieldsInsteadOfGuessesOrRawEventContent() throws {
        let suggestion = TicketRouteSuggestion(
            sourceDescription: "PRIVATE CALENDAR NAME", subtitle: "PRIVATE EVENT TITLE",
            originGuess: "Old origin", destinationGuess: "Old destination", trainNumberGuess: "999",
            departureDate: Date(timeIntervalSince1970: 1_700_000_000),
            requiresDepartureTime: true, departureTimeZoneIdentifier: "America/New_York",
            calendarSource: CalendarJourneySource(eventKey: "opaque-event-hash", revision: "opaque-revision-hash")
        )
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        let request = suggestion.journeySearchRequest(
            origin: "  Washington Union Station  ", destination: " New York Penn Station ",
            trainNumber: " 176 ", departureDate: departure
        )
        let source = try XCTUnwrap(request.calendarSource)
        let details = try XCTUnwrap(source.details)

        XCTAssertEqual(source.eventKey, "opaque-event-hash")
        XCTAssertEqual(source.revision, "opaque-revision-hash")
        XCTAssertEqual(details.originName, "Washington Union Station")
        XCTAssertEqual(details.destinationName, "New York Penn Station")
        XCTAssertEqual(details.trainNumber, "176")
        XCTAssertEqual(details.departureDate, departure)
        XCTAssertEqual(details.timeZoneIdentifier, "America/New_York")
        XCTAssertTrue(details.isAllDay)
        XCTAssertNil(suggestion.calendarSource?.details, "Preparing a request must not mutate the unconfirmed suggestion.")
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(source), encoding: .utf8))
        XCTAssertFalse(encoded.contains("PRIVATE"))
        XCTAssertFalse(encoded.contains("Old origin"))
        XCTAssertFalse(encoded.contains("Old destination"))
    }

    func testCalendarRequestKeepsBlankNumberAndUnspecifiedZoneAbsent() throws {
        let suggestion = TicketRouteSuggestion(
            sourceDescription: "Calendar",
            calendarSource: CalendarJourneySource(eventKey: "event", revision: "revision")
        )
        let request = suggestion.journeySearchRequest(
            origin: "London", destination: "Paris", trainNumber: " \n ", departureDate: .now
        )
        let details = try XCTUnwrap(request.calendarSource?.details)
        XCTAssertNil(details.trainNumber)
        XCTAssertNil(details.timeZoneIdentifier)
        XCTAssertFalse(details.isAllDay)
    }

    func testShareRequestDoesNotInventCalendarProvenance() {
        let request = TicketRouteSuggestion(sourceDescription: "Shared text").journeySearchRequest(
            origin: "London", destination: "Paris", trainNumber: "9032", departureDate: .now
        )
        XCTAssertNil(request.calendarSource)
    }
}
