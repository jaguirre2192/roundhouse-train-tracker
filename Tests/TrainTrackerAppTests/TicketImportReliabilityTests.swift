import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class TicketImportReliabilityTests: XCTestCase {
    func testFromAndToLabelsIgnoreDepartureAndArrivalDateMetadata() async {
        let parsed = await parse("""
        Amtrak Train 171
        From: NEW YORK PENN STATION
        To: Washington Union Station
        Departure: 2026-11-14T14:00:00Z
        Arrival: 2026-11-14T17:00:00Z
        Seat 14A
        """)
        XCTAssertEqual(parsed.suggestion.originGuess, "NEW YORK PENN STATION")
        XCTAssertEqual(parsed.suggestion.destinationGuess, "Washington Union Station")
        XCTAssertTrue(review(parsed.suggestion).missingFields.isEmpty)
    }

    func testExplicitUTCDepartureSurvivesParsingReviewAndStationResolution() async throws {
        let parsed = await parse("SNCF TGV 6611\nParis Gare de Lyon to Lyon Part Dieu\nDeparture: 2026-11-14T14:00:00Z")
        let client = ScriptedJourneySearchClient(places: [
            .success([place("paris", "Paris Gare de Lyon")]),
            .success([place("lyon", "Lyon Part Dieu")])
        ])
        let store = review(parsed.suggestion, client: client)
        let prefill = try await ImportedJourneyPrefill.resolve(XCTUnwrap(store.makeRequest()), using: client)
        XCTAssertEqual(prefill.departureTime, date("2026-11-14T14:00:00Z"))
    }

    func testExplicitOffsetInRepeatedDSTHourSurvivesDraftReopening() async throws {
        let parsed = await parse("Amtrak train 66\nNew York Penn Station to Boston South Station\nDeparture: 2027-11-07T01:30:00-05:00")
        let client = ScriptedJourneySearchClient(places: [
            .success([place("new-york", "New York Penn Station", country: "US", zone: "America/New_York")]),
            .success([place("boston", "Boston South Station", country: "US", zone: "America/New_York")])
        ])
        let store = review(parsed.suggestion, client: client)
        // An unrelated edit must not erase the explicit choice of the second 01:30.
        store.setTrainNumber("67")
        let saved = try JSONDecoder().decode(TicketRouteSuggestion.self, from: JSONEncoder().encode(store.suggestion))
        let reopened = review(saved, client: client)
        let prefill = try await ImportedJourneyPrefill.resolve(XCTUnwrap(reopened.makeRequest()), using: client)
        XCTAssertEqual(prefill.departureTime, date("2027-11-07T06:30:00Z"))
    }

    func testMixedDepartureFormatsRequireDateReviewInsteadOfChoosingFirst() async {
        let parsed = await parse("SNCF TGV 6611\nParis Gare de Lyon to Lyon Part Dieu\nDeparture: 2026-11-14T14:00:00Z\nDeparture: 15 November 2026 16:00")
        XCTAssertTrue(parsed.details.hasConflictingDates)
        let store = review(parsed.suggestion)
        XCTAssertTrue(store.missingFields.contains(.date))
        XCTAssertNil(store.makeRequest())
    }

    func testConnectedRoundTripRequiresChoosingACompleteJourneyBeforeSearch() async {
        let parsed = await parse(Self.connectedRoundTrip)
        XCTAssertNil(parsed.suggestion.originGuess)
        XCTAssertNil(parsed.suggestion.destinationGuess)
        let store = review(parsed.suggestion)
        store.start()
        XCTAssertNotEqual(store.stage, .matching)
        XCTAssertEqual(Set(store.missingFields), Set([.origin, .destination, .date, .time]))
        XCTAssertFalse(store.canBeginMatching)
        store.cancelMatching()
    }

    static let connectedRoundTrip = """
    Train ticket
    From: London St Pancras
    To: Paris Gare du Nord
    From: Paris Gare du Nord
    To: Lyon Part Dieu
    From: Lyon Part Dieu
    To: Paris Gare du Nord
    From: Paris Gare du Nord
    To: London St Pancras
    Outbound: 14 November 2026 10:00
    Return: 21 November 2026 10:00
    """

    private func parse(_ text: String) async -> ParsedTicketImport {
        let data = Data(text.utf8)
        let manifest = ShareManifest(id: UUID(), createdAt: date("2026-11-12T12:00:00Z"), kind: .text,
                                     payloadFilename: "payload", suggestedFilename: nil, sizeBytes: data.count)
        return await ShareImportParser.parseWithDetails(manifest: manifest, payload: data)
    }

    private func review(_ suggestion: TicketRouteSuggestion, client: ScriptedJourneySearchClient = .init()) -> SmartJourneyReviewStore {
        SmartJourneyReviewStore(suggestion: suggestion, client: client, planTracker: RecordingJourneyPlanTracker(),
                                plans: { [] }, now: { self.date("2026-11-12T12:00:00Z") })
    }

    private func place(_ id: String, _ name: String, country: String = "FR", zone: String = "Europe/Paris") -> RailPlace {
        JourneySearchStoreFixtures.place(id: id, name: name, kind: .station, country: country, timeZone: zone)
    }

    private func date(_ text: String) -> Date { JourneySearchStoreFixtures.date(text) }
}
