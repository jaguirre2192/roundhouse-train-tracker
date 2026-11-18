import Foundation
import XCTest
@testable import TrainTracker

final class CalendarTrainEvidenceRegressionTests: XCTestCase {
    func testDinnerTitleAndPostalCodeDoNotBecomeATrainJourney() {
        let title = "AB Future of Design Summit 2026 → Speakers' Dinner"
        for postcode in ["EC2N 2HE", "EC1A 1BB", "EC 2N 2HE"] {
            let event = snapshot(title: title, location: "Example Hall, London \(postcode)")
            XCTAssertNil(CalendarJourneyClassifier.classify(event), postcode)
            XCTAssertNil(TicketRouteTextHeuristics.extractTrainNumber(from: event.location ?? ""), postcode)
        }
    }

    func testEventYearsAndArrowsDoNotSupplyStationEvidence() {
        for title in [
            "AB Future of Design Summit 2026 → Speakers' Dinner",
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

    func testFlightTransfersAndNonTravelActivitiesNeverBecomeJourneySuggestions() {
        for event in [
            snapshot(title: "Flight BA178: New York JFK → London Heathrow",
                     notes: "Train 171 connects the airport with downtown."),
            snapshot(title: "BA178: New York JFK → London Heathrow",
                     notes: "Train 171 connects the airport with downtown."),
            snapshot(title: "Outbound flight to London", notes: "Ground transfer: Eurostar 9032",
                     location: "London St Pancras → Paris Gare du Nord"),
            snapshot(title: "AB Future of Design Summit 2026 → Speakers' Dinner",
                     notes: "Nearest station: Amtrak, three blocks away."),
            snapshot(title: "Dinner at the train station"),
            snapshot(title: "Train for marathon"),
            snapshot(title: "Board retreat", notes: "Nearest station: Amtrak Boston South Station"),
            snapshot(title: "Regional offsite", notes: "Some attendees might take the train.", location: "Bath → Bristol"),
            snapshot(title: "Graduation party", location: "Ave 416 Boston to New York"),
            snapshot(title: "", notes: "Meet by the train station")
        ] {
            XCTAssertNil(CalendarImportClient.candidate(for: event, includingEventKeys: []), event.title)
        }
    }

    func testCalendarBookingFieldsOutrankTheVenueAddress() throws {
        let event = snapshot(title: "Train reservation",
                             notes: "Ground transfer: Train 171 to the hotel\nEurostar 9014\nFrom: London St Pancras\nTo: Paris Gare du Nord",
                             location: "Ave 416")
        let candidate = try XCTUnwrap(CalendarImportClient.candidate(for: event, includingEventKeys: []))
        XCTAssertEqual(candidate.classification.trainNumberGuess, "9014")
        XCTAssertEqual(candidate.classification.originGuess, "London St Pancras")
        XCTAssertEqual(candidate.classification.destinationGuess, "Paris Gare du Nord")
        XCTAssertTrue(CalendarCandidateActionPolicy.canFindDirectly(candidate))

        let locationRoute = snapshot(title: "Travel", location: "ICE 612 Köln Hbf → Berlin Hbf\nGround transfer: Train 171")
        let locationCandidate = try XCTUnwrap(CalendarJourneyClassifier.classify(locationRoute))
        XCTAssertEqual(locationCandidate.trainNumberGuess, "ICE 612")
        XCTAssertEqual(locationCandidate.destinationGuess, "Berlin Hbf")

        let noNumber = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(
            title: "Travel", location: "Train from London to York"
        )))
        XCTAssertEqual(noNumber.originGuess, "London")
        XCTAssertEqual(noNumber.destinationGuess, "York")
        XCTAssertNil(noNumber.trainNumberGuess)
    }

    func testLocalLanguageStationLabelsKeepTheBookedDirectionAndService() throws {
        for (title, notes, origin, destination, number) in [
            ("ICE 612", "Von: Köln Hbf\nNach: Berlin Hbf", "Köln Hbf", "Berlin Hbf", "ICE 612"),
            ("Billete Renfe AVE 03143", "Origen: Madrid Puerta de Atocha\nDestino: Barcelona Sants",
             "Madrid Puerta de Atocha", "Barcelona Sants", "AVE 03143"),
            ("TGV INOUI 6123", "Gare de départ : Paris Gare de Lyon\nGare d’arrivée : Lyon Part-Dieu",
             "Paris Gare de Lyon", "Lyon Part-Dieu", "TGV 6123")
        ] {
            let candidate = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(title: title, notes: notes)))
            XCTAssertEqual(candidate.confidence, .high, title)
            XCTAssertEqual(candidate.originGuess, origin, title)
            XCTAssertEqual(candidate.destinationGuess, destination, title)
            XCTAssertEqual(candidate.trainNumberGuess, number, title)

            // Shared text, email and OCR all present the boarding document as one text field.
            let shared = try XCTUnwrap(TicketRouteTextHeuristics.match(title: title + "\n" + notes, supportingText: []))
            XCTAssertEqual(shared.originGuess, origin, title)
            XCTAssertEqual(shared.destinationGuess, destination, title)
            XCTAssertEqual(shared.trainMatchingIdentifier, number, title)
        }
    }

    func testExplicitTrainToAClientMeetingStillSuppliesTheBookedStations() throws {
        let event = snapshot(title: "Amtrak 2155: New York Penn → Washington Union Station for client meeting")
        let result = try XCTUnwrap(CalendarJourneyClassifier.classify(event))
        XCTAssertEqual(result.originGuess, "New York Penn")
        XCTAssertEqual(result.destinationGuess, "Washington Union Station")
        XCTAssertEqual(result.trainNumberGuess, "2155")
        XCTAssertNil(CalendarJourneyClassifier.classify(snapshot(title: "Amtrak project meeting",
                                                                notes: "Take train 2155 to get there.")))
    }

    func testFrecciarossaModelNameNeverSuppliesAServiceNumber() throws {
        let route = "Roma Termini → Milano Centrale"
        let model = try XCTUnwrap(CalendarImportClient.candidate(for: snapshot(
            title: "Trenitalia Frecciarossa 1000: " + route), includingEventKeys: []))
        XCTAssertNil(model.classification.trainNumberGuess)
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(model))
        for (title, notes) in [
            ("Frecciarossa 1000 9640: " + route, nil as String?),
            ("Trenitalia Frecciarossa 1000: " + route, "Treno n. 9640"),
            ("Frecciarossa 1000 Treno 9640: " + route, nil)
        ] {
            let candidate = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(title: title, notes: notes)))
            XCTAssertEqual(candidate.trainNumberGuess, "9640", title)
            XCTAssertEqual(candidate.originGuess, "Roma Termini", title)
            XCTAssertEqual(candidate.destinationGuess, "Milano Centrale", title)
        }
    }

    func testStructuredDanishSwissJapaneseAndTaiwaneseTickets() throws {
        for (title, notes, origin, destination, number) in [
            ("DSB billet", "Fra: København H\nTil: Aarhus H\nLyntog 25, Plads 31", "København H", "Aarhus H", "25" as String?),
            ("SBB: Zürich HB → Basel SBB", nil, "Zürich HB", "Basel SBB", nil),
            ("CFF: Genève-Cornavin → Lausanne", nil, "Genève-Cornavin", "Lausanne", nil),
            ("新幹線 のぞみ 23 東京 → 新大阪", nil, "東京", "新大阪", "23"),
            ("新幹線 のぞみ23号 東京→新大阪", nil, "東京", "新大阪", "23"),
            ("台灣高鐵 123 台北 → 左營", nil, "台北", "左營", "123"),
            ("臺灣高鐵 車次：0123 台北→左營", nil, "台北", "左營", "0123")
        ] {
            let candidate = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(title: title, notes: notes)), title)
            XCTAssertEqual(candidate.originGuess, origin, title)
            XCTAssertEqual(candidate.destinationGuess, destination, title)
            XCTAssertEqual(candidate.trainNumberGuess, number, title)
            XCTAssertEqual(candidate.confidence, .high, title)
            let sharedText = [title, notes].compactMap { $0 }.joined(separator: "\n")
            let shared = try XCTUnwrap(TicketRouteTextHeuristics.match(title: sharedText, supportingText: []), title)
            XCTAssertEqual(shared.originGuess, origin, title)
            XCTAssertEqual(shared.destinationGuess, destination, title)
            XCTAssertEqual(shared.trainNumberGuess, number, title)
        }
    }

    func testExplicitEuropeanTrainHeadingsAcceptNativeDirectionWords() throws {
        for (title, origin, destination) in [
            ("Fahrt mit ICE 612 von Köln Hbf nach Berlin Hbf", "Köln Hbf", "Berlin Hbf"),
            ("Train de Paris Gare de Lyon à Lyon Part-Dieu", "Paris Gare de Lyon", "Lyon Part-Dieu"),
            ("Tren de Madrid Puerta de Atocha a Barcelona Sants", "Madrid Puerta de Atocha", "Barcelona Sants")
        ] {
            let candidate = try XCTUnwrap(CalendarJourneyClassifier.classify(snapshot(title: title)), title)
            XCTAssertEqual(candidate.originGuess, origin, title)
            XCTAssertEqual(candidate.destinationGuess, destination, title)
            XCTAssertEqual(candidate.confidence, .high, title)
        }
    }

    func testIncidentalLocalizedRailBrandsAndUnqualifiedDirectionsAreIgnored() {
        for event in [
            snapshot(title: "Team lunch", notes: "Nearest station: SBB Zürich HB"),
            snapshot(title: "SBB: Board elections → Annual results"),
            snapshot(title: "Planning", notes: "DSB has a new ticket campaign", location: "København H → Aarhus H"),
            snapshot(title: "Lunch invitation", notes: "新幹線 のぞみ 23 東京 → 新大阪"),
            snapshot(title: "Planning", notes: "台灣高鐵 123", location: "台北 → 左營"),
            snapshot(title: "Museum of the Frecciarossa 1000"),
            snapshot(title: "Frecciarossa 1000 project meeting", notes: "Roma Termini → Milano Centrale"),
            snapshot(title: "Weekend", notes: "De Madrid a Barcelona"),
            snapshot(title: "Team offsite", notes: "Von Köln nach Berlin")
        ] {
            XCTAssertNil(CalendarJourneyClassifier.classify(event), event.title)
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
