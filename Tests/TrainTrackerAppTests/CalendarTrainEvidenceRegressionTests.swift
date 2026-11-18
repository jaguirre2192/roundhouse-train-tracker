import Foundation
import XCTest
@testable import TrainTracker

final class CalendarTrainEvidenceRegressionTests: XCTestCase {
    func testDinnerTitleAndPostalCodeDoNotBecomeATrainJourney() {
        let title = "FT Future of AI Summit 2026 → Speakers' Dinner"
        for postcode in ["EC2N 2HE", "EC1A 1BB", "EC 2N 2HE"] {
            let event = snapshot(title: title, location: "Example Hall, London \(postcode)")
            XCTAssertNil(CalendarJourneyClassifier.classify(event), postcode)
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: event.location ?? ""), postcode)
        }
    }

    func testEventYearsAndArrowsDoNotSupplyStationEvidence() {
        for title in [
            "FT Future of AI Summit 2026 → Speakers' Dinner",
            "Technology Conference 2026 -> Delegates’ Reception",
            "Speakers' Dinner → Evening Reception",
            "Annual Summit 2026 → London"
        ] {
            XCTAssertNil(TicketRouteTextHeuristics.extractRoute(from: title), title)
            XCTAssertNil(CalendarJourneyClassifier.classify(snapshot(
                title: title, notes: "The nearest train station is a short walk from the venue."
            )), title)
        }
    }

    func testAlphanumericCodesNeedAnExplicitTrainLabel() {
        for code in ["2N", "G1234", "1D16", "123A"] {
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: "EC\(code)"), code)
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: "EC \(code)"), code)
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: "IR\(code)"), code)
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: "IR \(code)"), code)
            XCTAssertEqual(TicketRouteTextHeuristics.extractTrainNumber(from: "Train \(code)"), code)
            let result = CalendarJourneyClassifier.classify(snapshot(title: "Train \(code) London → York"))
            XCTAssertEqual(result?.trainNumberGuess, code)
            XCTAssertEqual(result?.originGuess, "London")
            XCTAssertEqual(result?.destinationGuess, "York")
        }
    }

    func testNumericRailwayProductsRemainRecognizableWithAndWithoutSpaces() throws {
        for (service, identifier) in [("ICE612", "ICE 612"), ("EC123", "EC 123"), ("IC 2026", "IC 2026"), ("IR576", "IR 576")] {
            let result = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(
                title: "\(service) München → Zürich"
            )), service)
            XCTAssertEqual(result.trainNumberGuess, identifier, service)
            XCTAssertEqual(result.originGuess, "München", service)
            XCTAssertEqual(result.destinationGuess, "Zürich", service)
            XCTAssertEqual(result.confidence, .high, service)
        }
    }

    func testGenericTitleWithActualRailBookingInNotesRemainsACandidate() throws {
        for notes in [
            "Eurostar 9032\nOrigin: London St. Pancras\nDestination: Paris Gare du Nord",
            "Train 9032\nOrigin: London St. Pancras\nDestination: Paris Gare du Nord",
            "Rail ticket\nOrigin: London St. Pancras\nDestination: Paris Gare du Nord"
        ] {
            let result = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(
                title: "Travel", notes: notes
            )), notes)
            XCTAssertEqual(result.originGuess, "London St. Pancras")
            XCTAssertEqual(result.destinationGuess, "Paris Gare du Nord")
            XCTAssertEqual(result.confidence, .high)
        }
    }

    func testStationNamesWithEventLikeWordsAndTerminalNumbersRemainValid() throws {
        for (title, origin, destination) in [
            ("Train 645 Summit → New York Penn Station", "Summit", "New York Penn Station"),
            ("Train 104 Exhibition Centre → Glasgow Central", "Exhibition Centre", "Glasgow Central"),
            ("Train G1234 Shanghai Hongqiao → Terminal 2", "Shanghai Hongqiao", "Terminal 2")
        ] {
            let result = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(title: title)), title)
            XCTAssertEqual(result.originGuess, origin, title)
            XCTAssertEqual(result.destinationGuess, destination, title)
            XCTAssertEqual(result.confidence, .high, title)
        }
    }

    private func snapshot(title: String, notes: String? = nil, location: String? = nil) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: "synthetic-regression-event", calendarTitle: "Test Calendar", title: title,
            notes: notes, location: location,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600), isAllDay: false
        )
    }
}
