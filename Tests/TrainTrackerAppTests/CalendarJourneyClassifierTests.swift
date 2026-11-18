import Foundation
import XCTest
@testable import TrainTracker

final class CalendarJourneyClassifierTests: XCTestCase {
    private func snapshot(
        title: String,
        notes: String? = nil,
        location: String? = nil,
        calendarTitle: String = "Personal"
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: UUID().uuidString,
            calendarTitle: calendarTitle,
            title: title,
            notes: notes,
            location: location,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            isAllDay: false
        )
    }

    func testHighConfidenceWhenOperatorAndRouteBothMatch() throws {
        let event = snapshot(title: "Amtrak Acela — Boston to New York", location: "South Station")
        let classification = try XCTUnwrap(CalendarJourneyClassifier.classify(event))

        XCTAssertEqual(classification.confidence, .high)
        XCTAssertEqual(classification.originGuess, "Boston")
        XCTAssertEqual(classification.destinationGuess, "New York")
        XCTAssertTrue(classification.evidence.contains("Mentions Amtrak"))
        XCTAssertTrue(classification.evidence.contains("Recognized a route pattern"))
    }

    func testMediumConfidenceWhenKeywordMatchesButNoRoute() throws {
        let event = snapshot(title: "Train booking confirmation")
        let classification = try XCTUnwrap(CalendarJourneyClassifier.classify(event))

        XCTAssertEqual(classification.confidence, .medium)
        XCTAssertNil(classification.originGuess)
        XCTAssertNil(classification.destinationGuess)
    }

    func testOrdinaryMeetingIsRejected() {
        let event = snapshot(title: "Team sync", notes: "Weekly planning", location: "Conference Room B")

        XCTAssertNil(CalendarJourneyClassifier.classify(event))
    }

    func testBareWordRailDoesNotMatchInsideOtherWords() {
        let event = snapshot(title: "Railroad crossing safety training refresher")

        // "training" and "railroad" should not trip the bare-word "train"/"rail" match.
        XCTAssertNil(CalendarJourneyClassifier.classify(event))
    }

    func testTrainNumberIsExtractedWhenPresent() throws {
        let event = snapshot(title: "Amtrak Train 2151 to Washington", location: "Origin: Philadelphia")
        let classification = try XCTUnwrap(CalendarJourneyClassifier.classify(event))

        XCTAssertEqual(classification.trainNumberGuess, "2151")
    }

    func testRouteInLocationIsUsedWhenTitleHasNoRoute() throws {
        let event = snapshot(title: "Eurostar booking", location: "London to Paris")
        let classification = try XCTUnwrap(CalendarJourneyClassifier.classify(event))

        XCTAssertEqual(classification.originGuess, "London")
        XCTAssertEqual(classification.destinationGuess, "Paris")
        XCTAssertEqual(classification.confidence, .high)
    }

    func testCalendarTitlePreservesCitiesAndRegions() throws {
        let event = snapshot(title: "Amtrak 176: Washington, DC → New York, NY")
        let result = try XCTUnwrap(CalendarJourneyClassifier.classify(event))

        XCTAssertEqual(result.originGuess, "Washington, DC")
        XCTAssertEqual(result.destinationGuess, "New York, NY")
        XCTAssertEqual(result.trainNumberGuess, "176")
        XCTAssertEqual(result.confidence, .high)
    }

    func testBookingNotesSupplySeparateStationFields() throws {
        let event = snapshot(
            title: "Eurostar 9032 booking",
            notes: "Departure: London St. Pancras\nArrival: Paris Gare du Nord\nSeat: 14A",
            location: "123 Example Street"
        )
        let result = try XCTUnwrap(CalendarJourneyClassifier.classify(event))

        XCTAssertEqual(result.originGuess, "London St. Pancras")
        XCTAssertEqual(result.destinationGuess, "Paris Gare du Nord")
        XCTAssertEqual(result.trainNumberGuess, "9032")
    }

    func testOperatorProjectMeetingIsRejectedEvenWithRouteInNotes() {
        let event = snapshot(title: "Amtrak project meeting", notes: "Washington to New York")
        XCTAssertNil(CalendarJourneyClassifier.classify(event))
    }

    func testUnrelatedNumberedCalendarFragmentsDoNotCreateCandidates() {
        let fixtures = [
            snapshot(title: "Dentist appointment", location: "Example Ave 416"),
            snapshot(title: "Committee review", notes: "EC 2026"),
            snapshot(title: "Annual planning", notes: "IC\n2028"),
            snapshot(title: "Budget review", notes: "ICE 416"),
            snapshot(title: "Reservation 416", notes: "Reference: 2028"),
            snapshot(title: "Airport pickup", notes: "Reference: 416", location: "London → Paris")
        ]
        for event in fixtures {
            XCTAssertNil(CalendarJourneyClassifier.classify(event), event.title)
        }
    }

    func testServiceNumberWithIndependentRouteContextRemainsACandidate() throws {
        let event = snapshot(title: "Travel", notes: "IC 2026", location: "Berlin → Leipzig")
        let classification = try XCTUnwrap(CalendarJourneyClassifier.classify(event))
        XCTAssertEqual(classification.trainNumberGuess, "IC 2026")
        XCTAssertEqual(classification.originGuess, "Berlin")
        XCTAssertEqual(classification.destinationGuess, "Leipzig")
        XCTAssertEqual(classification.confidence, .high)
    }

    func testPrintedCalendarProductDoesNotMatchAnotherFamilyWithTheSameNumber() throws {
        let event = snapshot(title: "Travel", notes: "IC 123", location: "Berlin → Leipzig")
        let classification = try XCTUnwrap(CalendarJourneyClassifier.classify(event))
        let time = JourneySearchStoreFixtures.date("2026-11-14T14:00:00Z")
        let ice = JourneySearchStoreFixtures.option(id: "ice", fingerprint: "ice", start: time,
                                                   end: time.addingTimeInterval(3600), trainNumber: "ICE 123")
        let preference = try XCTUnwrap(ImportedJourneyAutoSelection(trainNumber: classification.trainNumberGuess,
            departureTime: "2026-11-14T14:00:00Z"))
        XCTAssertEqual(preference.decision(in: [ice]), .choose(.noMatch))
    }

    func testExplicitTrainAndOperatorReferencesRemainCandidatesWithoutRoutes() throws {
        for title in ["Train 416", "Amtrak 416"] {
            let classification = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(title: title)), title)
            XCTAssertEqual(classification.trainNumberGuess, "416", title)
            XCTAssertEqual(classification.confidence, .medium, title)
        }
    }
}
