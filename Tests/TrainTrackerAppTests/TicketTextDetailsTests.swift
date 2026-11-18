import Foundation
import XCTest
@testable import TrainTracker

final class TicketTextDetailsTests: XCTestCase {
    func testLabelledEnglishDepartureKeepsPrintedLocalTimeAndSeatDetails() {
        let text = """
        Amtrak Acela 2150
        Boston South Station to New York Penn Station
        Departure: Tuesday, September 22, 2026 8:05 AM
        Arrival: 11:59 AM
        Coach 5  Seat 14A
        Booking reference: ABC123
        """
        let details = TicketTextDetails.extract(from: text, origin: "Boston South Station")
        XCTAssertEqual(details.departure, TicketWallClock(year: 2026, month: 9, day: 22, hour: 8, minute: 5))
        XCTAssertNil(details.departureInstant)
        XCTAssertEqual(details.coach, "5")
        XCTAssertEqual(details.seat, "14A")
        XCTAssertEqual(details.bookingReference, "ABC123")
        XCTAssertEqual(details.timeZoneIdentifier, "America/New_York")
        XCTAssertFalse(details.hasConflictingDates)
    }

    func testDayFirstDateOnNextLineAndTwentyFourHourTime() {
        let text = """
        Eurostar 9032 London → Paris
        Outbound
        22 Sep 2026 06:01
        """
        let details = TicketTextDetails.extract(from: text, origin: "London")
        XCTAssertEqual(details.departure, TicketWallClock(year: 2026, month: 9, day: 22, hour: 6, minute: 1))
    }

    func testExplicitOffsetProducesInstantAndMatchingWallClock() throws {
        let details = TicketTextDetails.extract(from: "Departure: 2026-09-22T08:05-04:00", origin: nil)
        XCTAssertEqual(details.departure, TicketWallClock(year: 2026, month: 9, day: 22, hour: 8, minute: 5))
        XCTAssertEqual(details.departureInstant, ISO8601DateFormatter().date(from: "2026-09-22T12:05:00Z"))
    }

    func testDateWithoutTimeLeavesTimeUnknown() {
        let details = TicketTextDetails.extract(from: "Train 305 Chicago to St. Louis\nTravel date: 2026-10-03", origin: "Chicago")
        XCTAssertEqual(details.departure, TicketWallClock(year: 2026, month: 10, day: 3))
        XCTAssertFalse(details.departure?.hasTime ?? true)
    }

    func testEmailHeaderAndPurchaseDatesAreNeverDepartures() {
        let text = """
        Date: Mon, 14 Sep 2026 10:22:01 -0400
        Sent: September 14, 2026 10:22 AM
        Booked on September 14, 2026 at 10:20 AM
        Your Amtrak trip from Boston to New York
        """
        let details = TicketTextDetails.extract(from: text, origin: "Boston")
        XCTAssertNil(details.departure)
        XCTAssertNil(details.departureInstant)
    }

    func testTwoDifferentTravelDatesAreConflictingAndNotChosen() {
        let text = """
        Outbound: Sep 22, 2026 8:05 AM
        Return: Sep 25, 2026 5:00 PM
        """
        let details = TicketTextDetails.extract(from: text, origin: nil)
        XCTAssertEqual(details.departure, TicketWallClock(year: 2026, month: 9, day: 22, hour: 8, minute: 5))

        let ambiguous = TicketTextDetails.extract(from: "Travel on 22 Sep 2026 or 23 Sep 2026", origin: nil)
        XCTAssertNil(ambiguous.departure)
        XCTAssertTrue(ambiguous.hasConflictingDates)
    }

    func testMultipleTimesOnTheDateLineLeaveTimeUnknown() {
        let details = TicketTextDetails.extract(from: "Sep 22, 2026  8:05 AM – 11:59 AM", origin: nil)
        XCTAssertEqual(details.departure?.day, 22)
        XCTAssertNil(details.departure?.hour)
        XCTAssertTrue(details.hasConflictingDates)
    }

    func testInvalidCalendarDatesAndDurationsAreIgnored() {
        XCTAssertNil(TicketTextDetails.extract(from: "Departure: Feb 30, 2026 8:05 AM", origin: nil).departure)
        let duration = TicketTextDetails.extract(from: "Departure: 2026-09-22\nJourney time 3:45 hrs", origin: nil)
        XCTAssertEqual(duration.departure, TicketWallClock(year: 2026, month: 9, day: 22))
    }

    func testTwelveHourClockBoundaries() {
        let midnight = TicketTextDetails.extract(from: "Departs Sep 22, 2026 12:15 AM", origin: nil)
        XCTAssertEqual(midnight.departure?.hour, 0)
        let noon = TicketTextDetails.extract(from: "Departs Sep 22, 2026 12:15 pm", origin: nil)
        XCTAssertEqual(noon.departure?.hour, 12)
    }

    func testArrivalTimesNeverBecomeDepartures() {
        let arrivalOnly = TicketTextDetails.extract(from: "Amtrak 171\nArrive Sep 20, 2026 1:05 PM", origin: nil)
        XCTAssertNil(arrivalOnly.departure)
        let bareLabel = TicketTextDetails.extract(from: "Departure:\nArrival: Sep 20, 2026 1:05 PM", origin: nil)
        XCTAssertNil(bareLabel.departure)
    }

    func testBookingReferenceCannotBecomeTrainNumber() {
        let details = TicketTextDetails(bookingReference: "612345")
        XCTAssertFalse(details.acceptsTrainNumber("612 345"))
        XCTAssertTrue(details.acceptsTrainNumber("171"))
        XCTAssertTrue(TicketTextDetails().acceptsTrainNumber("2150"))
    }

    func testWallClockRequestValueRoundTripsAndResolvesInStationZone() throws {
        let clock = TicketWallClock(year: 2026, month: 9, day: 22, hour: 8, minute: 5)
        XCTAssertEqual(clock.requestValue, "2026-09-22T08:05:00")
        XCTAssertEqual(TicketWallClock(requestValue: clock.requestValue), clock)
        XCTAssertEqual(TicketWallClock(requestValue: "2026-09-22"), TicketWallClock(year: 2026, month: 9, day: 22))
        XCTAssertNil(TicketWallClock(requestValue: "2026-09-22T08:05:00Z"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(clock.date(in: newYork), ISO8601DateFormatter().date(from: "2026-09-22T12:05:00Z"))
        XCTAssertEqual(
            TicketJourneySearchPrefill.departureDate(clock.requestValue, timeZoneIdentifier: "Europe/Paris"),
            ISO8601DateFormatter().date(from: "2026-09-22T06:05:00Z")
        )
    }
}
