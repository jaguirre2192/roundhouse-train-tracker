import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class EuropeanTicketImportTests: XCTestCase {
    func testConflictingPrintedFamiliesRequireChoiceEvenForOneReturnedService() async throws {
        let parsed = await parse(service: "IC 123\nICE 123", origin: "Paris", destination: "Amsterdam",
                                 departure: "2026-11-14T14:00:00Z")
        let reopened = try JSONDecoder().decode(TicketRouteSuggestion.self,
                                               from: JSONEncoder().encode(parsed.suggestion))
        let client = ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [.success(JourneySearchStoreFixtures.page(options: [option("ICE 123")]))])
        let store = SmartJourneyReviewStore(suggestion: reopened, client: client,
            planTracker: RecordingJourneyPlanTracker(), plans: { [] }, now: { self.date("2026-11-12T12:00:00Z") })
        defer { store.cancelMatching() }
        store.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.isPreparingSearch || store.search.isJourneyTaskActive {
            guard ContinuousClock.now < deadline else { return XCTFail("Matching timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.search.phase, .showingOutbound)
        XCTAssertNil(store.search.selectedOutbound)
    }

    func testPrintedFamilySurvivesImportBeforeAutomaticSelection() async throws {
        for (printed, conflicting) in [("IC", "ICE"), ("ICE", "IC"), ("RJ", "RJX"),
                                        ("RJX", "RJ"), ("EC", "IC"), ("TGV INOUI", "IC"), ("AVE", "IC")] {
            let parsed = await parse(service: "Train \(printed) 123", origin: "Berlin", destination: "Leipzig",
                                     departure: "2026-11-14T14:00:00Z")
            let preference = try XCTUnwrap(ImportedJourneyAutoSelection(
                trainNumber: parsed.suggestion.trainNumberGuess, departureTime: "2026-11-14T14:00:00Z"))
            XCTAssertEqual(preference.decision(in: [option("\(conflicting) 123")]), .choose(.noMatch), printed)
            let numeric = option("123")
            XCTAssertEqual(preference.decision(in: [numeric]), .review(numeric), printed)
        }
    }

    func testFamilyEvidenceDoesNotBorrowAnotherServicesNumberOrOverrideBookingGuard() async throws {
        let separate = await parse(service: "Train 123\nICE 456", origin: "Berlin", destination: "Leipzig",
                                   departure: "2026-11-14T14:00:00Z")
        XCTAssertEqual(separate.suggestion.trainNumberGuess, "123")
        let referenceFamily = await parse(service: "Train 123\nBooking reference: IC123", origin: "Berlin", destination: "Leipzig",
                                          departure: "2026-11-14T14:00:00Z")
        XCTAssertEqual(referenceFamily.suggestion.trainNumberGuess, "123")
        let ambiguous = await parse(service: "IC 123\nICE 123", origin: "Berlin", destination: "Leipzig",
                                    departure: "2026-11-14T14:00:00Z")
        let preference = try XCTUnwrap(ImportedJourneyAutoSelection(
            trainNumber: ambiguous.suggestion.trainNumberGuess, departureTime: "2026-11-14T14:00:00Z"))
        XCTAssertEqual(preference.decision(in: [option("IC 123"), option("ICE 123")]), .choose(.ambiguous))
        let reference = await parse(service: "IC 12345\nBooking reference: 12345", origin: "Berlin", destination: "Leipzig",
                                    departure: "2026-11-14T14:00:00Z")
        XCTAssertNil(reference.suggestion.trainNumberGuess)
        let onlyReference = await parse(service: "Booking reference: IC123", origin: "Berlin", destination: "Leipzig",
                                       departure: "2026-11-14T14:00:00Z")
        XCTAssertNil(onlyReference.suggestion.trainNumberGuess)
    }

    func testStructuredProviderProductConstrainsANumericOnlyServiceNumber() async throws {
        let parsed = await parse(service: "IC 123", origin: "Paris", destination: "Amsterdam",
                                 departure: "2026-11-14T14:00:00Z")
        let preference = try XCTUnwrap(ImportedJourneyAutoSelection(
            trainNumber: parsed.suggestion.trainNumberGuess, departureTime: "2026-11-14T14:00:00Z"))
        XCTAssertEqual(preference.decision(in: [option("123", product: "ICE 123")]), .choose(.noMatch))
        for product in ["IC 123", "IC8", "Intercity", "High speed"] {
            let matching = option("123", product: product)
            XCTAssertEqual(preference.decision(in: [matching]), .review(matching), product)
        }
    }

    func testEuropeanProductsPreserveStationsTrainNumberAndExplicitInstant() async {
        let fixtures = [
            ("SNCF TGV INOUI 6611", "Paris Gare de Lyon", "Lyon Part Dieu", "TGV 6611"),
            ("DB ICE 575", "Berlin Hauptbahnhof", "München Hbf", "ICE 575"),
            ("ÖBB Railjet 162", "Wien Hauptbahnhof", "Salzburg Hbf", "RJ 162"),
            ("SBB IC 815", "Zürich HB", "Bern", "IC 815"),
            ("SNCB IC 529", "Bruxelles-Midi", "Gent-Sint-Pieters", "IC 529"),
            ("Eurostar 9024", "London St Pancras International", "Paris Gare du Nord", "9024"),
            ("SBB EC 197", "Zürich HB", "München Hbf", "EC 197")
        ]
        for (service, origin, destination, number) in fixtures {
            let parsed = await parse(service: service, origin: origin, destination: destination,
                                     departure: "2026-11-14T15:00:00+01:00")
            XCTAssertEqual(parsed.suggestion.originGuess, origin, service)
            XCTAssertEqual(parsed.suggestion.destinationGuess, destination, service)
            XCTAssertEqual(parsed.suggestion.trainNumberGuess, number, service)
            XCTAssertEqual(parsed.suggestion.departureDate, date("2026-11-14T14:00:00Z"), service)
            XCTAssertNil(parsed.suggestion.departureWallClock, service)
            XCTAssertFalse(parsed.details.hasConflictingDates, service)
        }
    }

    func testRailjetAbbreviationsRetainServiceNumber() async {
        for (service, number) in [("ÖBB RJ 162", "RJ 162"), ("ÖBB RJX 662", "RJX 662"), ("ÖBB RJX19962", "RJX 19962")] {
            let parsed = await parse(service: service, origin: "Wien Hauptbahnhof",
                                     destination: "Salzburg Hbf", departure: "2026-11-14T15:00:00+01:00")
            XCTAssertEqual(parsed.suggestion.trainNumberGuess, number, service)
            XCTAssertEqual(parsed.suggestion.originGuess, "Wien Hauptbahnhof", service)
            XCTAssertEqual(parsed.suggestion.destinationGuess, "Salzburg Hbf", service)
        }
    }

    func testSlovenianInterRegioNumberSurvivesTheRealLiveImportPayload() async {
        // The live backend publishes tripShortName "IR 576". The import flow
        // prints that value verbatim after Train, with an explicit UTC instant.
        for service in ["Train IR 576", "Train IR576", "IR 576", "IR576"] {
            let parsed = await parse(service: service, origin: "Ljubljana", destination: "Maribor",
                                     departure: "2026-11-17T09:15:00Z")
            XCTAssertEqual(parsed.suggestion.trainNumberGuess, "IR 576", service)
            XCTAssertEqual(parsed.suggestion.originGuess, "Ljubljana", service)
            XCTAssertEqual(parsed.suggestion.destinationGuess, "Maribor", service)
            XCTAssertEqual(parsed.suggestion.departureDate, date("2026-11-17T09:15:00Z"), service)
        }
    }

    func testInterRegioAbbreviationsStillRequireContextAndCannotBorrowMetadataOrDates() throws {
        for text in ["IR 576", "IR576", "IR\n576 Example Street", "IR 2026-11-17", "IR2026-11-17",
                     "Booking reference: IR576", "Seat IR576"] {
            XCTAssertNil(TicketRouteTextHeuristics.match(title: text, supportingText: []), text)
        }
        let route = try XCTUnwrap(TicketRouteTextHeuristics.match(title: "IR576 Ljubljana → Maribor", supportingText: []))
        XCTAssertEqual(route.trainMatchingIdentifier, "IR 576")
        XCTAssertEqual(route.originGuess, "Ljubljana")
        XCTAssertEqual(route.destinationGuess, "Maribor")
    }

    func testRailjetAbbreviationsStillRequireJourneyContext() {
        for text in ["RJ 162", "RJX 662", "RJX\n662 Example Street", "RJX 2026-11-14"] {
            XCTAssertNil(TicketRouteTextHeuristics.match(title: text, supportingText: []), text)
        }
    }

    func testCompactServicePrefixDoesNotBecomePartOfStation() throws {
        let route = try XCTUnwrap(TicketRouteTextHeuristics.extractRoute(from: "RJX19962 Wien → Salzburg"))
        XCTAssertEqual(route.origin, "Wien")
        XCTAssertEqual(route.destination, "Salzburg")
    }

    func testCrossBorderSummerDepartureRetainsOriginOffsetAcrossMidnight() async {
        let parsed = await parse(service: "Eurostar 9024", origin: "London St Pancras International",
                                 destination: "Paris Gare du Nord", departure: "2027-06-14T00:30:00+01:00")
        XCTAssertEqual(parsed.suggestion.departureDate, date("2027-06-13T23:30:00Z"))
        XCTAssertNil(parsed.suggestion.departureWallClock)
    }

    private func parse(service: String, origin: String, destination: String, departure: String) async -> ParsedTicketImport {
        let payload = Data("""
        Train ticket
        \(service)
        From: \(origin)
        To: \(destination)
        Departure: \(departure)
        Seat 14A
        """.utf8)
        let manifest = ShareManifest(id: UUID(), createdAt: date("2026-11-12T12:00:00Z"), kind: .text,
                                     payloadFilename: "payload", suggestedFilename: nil, sizeBytes: payload.count)
        return await ShareImportParser.parseWithDetails(manifest: manifest, payload: payload)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func option(_ number: String, product: String? = nil) -> JourneyOption {
        let base = JourneySearchStoreFixtures.option(id: number, fingerprint: number,
            start: date("2026-11-14T14:00:00Z"), end: date("2026-11-14T16:00:00Z"), trainNumber: number)
        guard let product, case let .rail(original) = base.segments[0] else { return base }
        let rail = RailJourneySegment(id: original.id, tripID: original.tripID, serviceDate: original.serviceDate,
            operatorName: original.operatorName, product: product, trainNumber: number, trainName: nil,
            from: original.from, to: original.to, intermediateCalls: [], isCancelled: false,
            isRealtime: false, isTrackable: true, untrackableReason: nil)
        return JourneyOption(id: base.id, fingerprint: base.fingerprint, startTime: base.startTime, endTime: base.endTime,
            duration: base.duration, transferCount: 0, segments: [.rail(rail)], badges: base.badges,
            trackability: base.trackability, realtimeFreshness: nil, attributions: [], trackingToken: base.trackingToken)
    }
}
