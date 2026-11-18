import Foundation
import XCTest
@testable import TrainTracker

final class TicketRouteTextHeuristicsTests: XCTestCase {
    func testCompiledPatternsAreReused() throws {
        let pattern = #"\b(?:amtrak|eurostar)\b"#
        let first = try XCTUnwrap(TicketTextPattern.expression(pattern))
        let second = try XCTUnwrap(TicketTextPattern.expression(pattern))

        XCTAssertTrue(first === second)
    }

    func testLargeCalendarClassificationStaysWithinInteractiveBudget() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var matches = 0
        for index in 0..<500 {
            let title = "Amtrak 171 Boston → New York"
            let notes = "Booking reference TEST\(index). Coach 4, seat 12A, platform 8."
            if TicketRouteTextHeuristics.match(title: title, supportingText: [notes]) != nil {
                matches += 1
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertEqual(matches, 500)
        XCTAssertLessThan(elapsed, 2.0, "500 calendar candidates should classify without a visible stall")
    }

    func testCalendarMoynihanStationAliasesPrefillBothDirections() throws {
        for destination in ["New York, Moynihan Train Hall at Penn Sta.",
                            "New York, Moynihan Train Hall at Penn Station",
                            "Moynihan Train Hall"] {
            let forward = try XCTUnwrap(TicketRouteTextHeuristics.match(
                title: "Train: Washington, Union Station to \(destination) Confirmation (TEST-REF)",
                supportingText: []))
            XCTAssertEqual(forward.originGuess, "Washington Union Station")
            XCTAssertEqual(forward.destinationGuess, "New York Penn Station")
            XCTAssertEqual(forward.confidence, .high)
            XCTAssertNil(forward.trainNumberGuess)

            let reverse = try XCTUnwrap(TicketRouteTextHeuristics.extractRoute(
                from: "Train: \(destination) to Washington, Union Station"))
            XCTAssertEqual(reverse.origin, "New York Penn Station")
            XCTAssertEqual(reverse.destination, "Washington Union Station")
        }
    }

    func testStationAliasDoesNotAcceptSurroundingProseOrOtherCities() {
        for destination in ["Moynihan Train Hall please arrive early", "Boston, Moynihan Train Hall",
                            "New York, Moynihan Train Hall at Penn Station to Boston",
                            "New York train to the station for our group this afternoon"] {
            XCTAssertNil(TicketRouteTextHeuristics.extractRoute(from: "Train: Washington to \(destination)"))
        }
    }

    func testExtractRouteHandlesArrowSeparator() throws {
        let route = try XCTUnwrap(TicketRouteTextHeuristics.extractRoute(from: "Chicago → Milwaukee"))
        XCTAssertEqual(route.origin, "Chicago")
        XCTAssertEqual(route.destination, "Milwaukee")
    }

    func testExtractRouteRejectsIdenticalEndpoints() {
        XCTAssertNil(TicketRouteTextHeuristics.extractRoute(from: "Chicago to Chicago"))
    }

    func testExtractTrainNumberIgnoresOverlyLongTokens() {
        XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: "Train ABCDEFGHIJ1234567"))
    }

    func testExtractTrainNumberIgnoresTokensWithoutDigits() {
        XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: "Train station renovation"))
    }

    func testMatchReturnsNilWithoutAnyStrongSignal() {
        XCTAssertNil(TicketRouteTextHeuristics.match(title: "Dentist appointment", supportingText: [nil]))
    }

    func testRoutePrefixesAreRemovedWithoutDiscardingCityRegions() throws {
        let fixtures = [
            ("Train from Washington to New York", "Washington", "New York"),
            ("Amtrak 176: Washington, DC → New York, NY", "Washington, DC", "New York, NY"),
            ("Amtrak Northeast Regional 176 Washington to New York", "Washington", "New York"),
            ("Amtrak Train no. 176 Washington to New York", "Washington", "New York"),
            ("Amtrak 176, Washington, DC → New York, NY", "Washington, DC", "New York, NY"),
            ("Train: BOSTON TO NEW YORK", "BOSTON", "NEW YORK"),
            ("Eurostar London→Paris", "London", "Paris"),
            ("Eurostar 9032 London->Paris", "London", "Paris"),
            ("TGV Paris – Lyon", "Paris", "Lyon"),
            ("Train: King's Cross to St. Louis!", "King's Cross", "St. Louis")
        ]
        for (text, origin, destination) in fixtures {
            let route = try XCTUnwrap(TicketRouteTextHeuristics.extractRoute(from: text), text)
            XCTAssertEqual(route.origin, origin, text)
            XCTAssertEqual(route.destination, destination, text)
        }
    }

    func testUnicodeStationsRetainAccentsAndNonLatinNames() throws {
        for (text, origin, destination) in [
            ("ICE 612 München → Zürich", "München", "Zürich"),
            ("Shinkansen 東京→京都", "東京", "京都"),
            ("TGV Aix-en-Provence to Paris Gare de Lyon", "Aix-en-Provence", "Paris Gare de Lyon")
        ] {
            let match = try XCTUnwrap(TicketRouteTextHeuristics.match(title: text, supportingText: []), text)
            XCTAssertEqual(match.originGuess, origin, text)
            XCTAssertEqual(match.destinationGuess, destination, text)
            XCTAssertEqual(match.confidence, .high, text)
        }
    }

    func testBookingFieldsDoNotSwallowSeparateMetadataOrAddresses() throws {
        let text = """
        Amtrak Northeast Regional 176
        Departure: Washington Union Station 08:30
        Arrival: New York Penn Station 11:45
        Seat: 14A
        Address: 123 Example Street
        Please bring your booking confirmation.
        """
        let match = try XCTUnwrap(TicketRouteTextHeuristics.match(title: text, supportingText: []))

        XCTAssertEqual(match.originGuess, "Washington Union Station")
        XCTAssertEqual(match.destinationGuess, "New York Penn Station")
        XCTAssertEqual(match.trainNumberGuess, "176")
        XCTAssertEqual(match.confidence, .high)
    }

    func testLabelledRouteSupportsStationAndOriginDestinationLabels() throws {
        for text in [
            "Departure station: London St. Pancras\nArrival station: Paris Gare du Nord",
            "Origin: London St. Pancras\nDestination: Paris Gare du Nord",
            "From: London St. Pancras\nTo: Paris Gare du Nord"
        ] {
            let route = try XCTUnwrap(TicketRouteTextHeuristics.extractRoute(from: text), text)
            XCTAssertEqual(route.origin, "London St. Pancras")
            XCTAssertEqual(route.destination, "Paris Gare du Nord")
        }
    }

    func testLabelledTimesAndMultipleLegsDoNotBecomeStations() {
        for text in [
            "Departure: 08:30\nArrival: 11:45",
            "Departure: Boston\nDeparture: Philadelphia\nArrival: New York",
            "Departure: Boston\nArrival: New York\nArrival: Philadelphia"
        ] {
            XCTAssertNil(TicketRouteTextHeuristics.extractRoute(from: text), text)
        }
    }

    func testTicketMetadataFollowingDestinationIsExcluded() throws {
        for text in [
            "Your Amtrak booking: Chicago to St. Louis, Train 305",
            "Your Amtrak booking: Chicago to St. Louis, Seat: 14A",
            "Train Chicago to St. Louis — Booking reference: TEST123",
            "Train Chicago to St. Louis\nPlease arrive 30 minutes early."
        ] {
            let route = try XCTUnwrap(TicketRouteTextHeuristics.extractRoute(from: text), text)
            XCTAssertEqual(route.origin, "Chicago", text)
            XCTAssertEqual(route.destination, "St. Louis", text)
        }
    }

    func testLongNotesElsewhereDoNotContaminateRoute() throws {
        let notes = "Amtrak booking\nWashington, DC → New York, NY\n" + String(repeating: "Read the booking details. ", count: 100)
        let route = try XCTUnwrap(TicketRouteTextHeuristics.extractRoute(from: notes))
        XCTAssertEqual(route.origin, "Washington, DC")
        XCTAssertEqual(route.destination, "New York, NY")
    }

    func testAmbiguousProseAndAddressesDoNotBecomeHighConfidenceRoutes() {
        for text in [
            "Amtrak to Washington",
            "Amtrak Train 2151 to Washington",
            "Train from Washington to New York to Boston",
            "Eurostar London → Paris → Lyon",
            "Train Boston → 123 Example Street",
            "Train Boston → New York, 123 Example Street",
            "Train Boston → Washington, DC 50 Example Avenue",
            "Train Boston to New York, please arrive early",
            "Train Boston to New York see attached details"
        ] {
            XCTAssertNil(TicketRouteTextHeuristics.extractRoute(from: text), text)
            XCTAssertNotEqual(TicketRouteTextHeuristics.match(title: text, supportingText: [])?.confidence, .high, text)
        }
    }

    func testOperatorAndProductTrainNumbersAreRecognized() {
        for (text, expected) in [
            ("Amtrak Northeast Regional 176", "176"),
            ("Amtrak Acela 2151", "2151"),
            ("Eurostar 9032", "9032"),
            ("Train no. 176", "176"),
            ("TRAIN NUMBER 176", "176"),
            ("Train #2151", "2151"),
            ("Train nº 176", "176"),
            ("ICE 612", "612"),
            ("TGV INOUI 6634", "6634"),
            ("Amtrak 176: Washington to New York", "176")
        ] {
            XCTAssertEqual(TicketRouteTextHeuristics.extractTrainNumber(from: text), expected, text)
        }
    }

    func testUnrelatedNumbersAndPartialWordsAreNotTrainNumbers() {
        for text in [
            "Booking reference: 176", "Seat: 14A", "123 Main Street", "trainer123",
            "restrain176", "Train station 176", "Amtrak 2026-09-15", "Train 09:30",
            "Unknown Railway 123", "Train ABCDEFGHIJ1234567", "Train 123456789"
        ] {
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: text), text)
        }
    }

    func testNonJourneyOperatorMentionsAreRejected() {
        for title in ["Amtrak project meeting", "Eurostar workshop", "Train station renovation", "Rail training"] {
            XCTAssertNil(TicketRouteTextHeuristics.match(title: title, supportingText: ["London to Paris"]), title)
        }
    }

    func testCancelledAndChangedBookingTextIsStillParseable() throws {
        for title in ["Amtrak booking cancelled", "Eurostar booking changed"] {
            let match = try XCTUnwrap(TicketRouteTextHeuristics.match(title: title, supportingText: ["London to Paris"]), title)
            XCTAssertEqual(match.originGuess, "London")
            XCTAssertEqual(match.destinationGuess, "Paris")
        }
    }

    func testSignalsUseWordBoundariesAndSearchBeyondFirstPartialWord() {
        XCTAssertNil(TicketRouteTextHeuristics.match(title: "Caltraining and parametration", supportingText: []))
        XCTAssertNotNil(TicketRouteTextHeuristics.match(title: "Restraint notes\nTrain booking confirmation", supportingText: []))
    }

    func testAmbiguousProductNumberExtractionDoesNotAloneQualifyAJourney() {
        for (fragment, number) in [("Example Ave 416", "416"), ("EC 2026", "2026"), ("IC 2028", "2028"), ("ICE 416", "416")] {
            // Extraction is useful once independent journey context exists; it is not proof
            // that an address, committee code, or other numbered item describes a train.
            XCTAssertEqual(TicketRouteTextHeuristics.extractTrainNumber(from: fragment), number, fragment)
            XCTAssertNil(TicketRouteTextHeuristics.match(title: "Appointment", supportingText: [fragment]), fragment)
        }
    }

    func testServicePrefixesCannotBorrowNumbersFromAnotherLine() {
        for text in ["Example Ave\n416", "EC\r\n2026", "IC\n2028", "ICE no.\n416", "Frecciarossa\n2028"] {
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: text), text)
            XCTAssertNil(TicketRouteTextHeuristics.match(title: "Appointment", supportingText: [text]), text)
        }
    }

    func testExplicitRailNumbersStillQualifyWithoutARoute() throws {
        for title in ["Train 416", "Amtrak 416", "Train\n416"] {
            let match = try XCTUnwrap(TicketRouteTextHeuristics.match(title: title, supportingText: []), title)
            XCTAssertEqual(match.trainNumberGuess, "416", title)
            XCTAssertEqual(match.confidence, .medium, title)
            XCTAssertNil(match.originGuess, title)
            XCTAssertNil(match.destinationGuess, title)
        }
        let contextual = try XCTUnwrap(TicketRouteTextHeuristics.match(title: "Rail ticket", supportingText: ["EC 2026"]))
        XCTAssertEqual(contextual.trainNumberGuess, "2026")
    }

    func testAllSupportedProductsKeepNumbersWhenARouteProvidesContext() throws {
        let fixtures = [
            ("Northeast Regional", "Boston", "New York"),
            ("Acela", "Boston", "New York"), ("Acela Express", "Boston", "New York"),
            ("TGV", "Paris", "Lyon"), ("TGV INOUI", "Paris", "Lyon"),
            ("ICE", "Berlin", "München"), ("IC", "Berlin", "Leipzig"),
            ("EC", "Zürich", "Milano"), ("AVE", "Madrid", "Barcelona"),
            ("Frecciarossa", "Roma", "Milano"), ("Frecciargento", "Roma", "Venezia"),
            ("Frecciabianca", "Genova", "Roma"), ("Railjet", "Wien", "Salzburg"),
            ("Shinkansen", "東京", "京都"), ("Nozomi", "東京", "京都"),
            ("Hikari", "東京", "名古屋"), ("Kodama", "東京", "熱海")
        ]
        for (product, origin, destination) in fixtures {
            let title = "\(product) 416 \(origin) → \(destination)"
            let match = try XCTUnwrap(TicketRouteTextHeuristics.match(title: title, supportingText: []), title)
            XCTAssertEqual(match.trainNumberGuess, "416", title)
            XCTAssertEqual(match.originGuess, origin, title)
            XCTAssertEqual(match.destinationGuess, destination, title)
            XCTAssertEqual(match.confidence, .high, title)
        }
    }
}
