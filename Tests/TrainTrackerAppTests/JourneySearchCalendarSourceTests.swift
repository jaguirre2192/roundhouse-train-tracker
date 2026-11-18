import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneySearchCalendarSourceTests: XCTestCase {
    @MainActor
    func testCalendarSourceSurvivesReviewThenClearsForFollowingManualSearch() async throws {
        let option = journeyOutboundOption()
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [option])),
                .success(JourneySearchStoreFixtures.page(options: [option])),
            ]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())

        await store.prefillTicketJourney(request(source: source))
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertEqual(try XCTUnwrap(store.reviewDraftForTracking).calendarSource, source)

        store.finishTrackingPersistence(planID: UUID())
        XCTAssertNil(store.preferredTrainNumber)
        XCTAssertNil(store.reviewDraftForTracking?.calendarSource)

        store.editSearch()
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertNil(try XCTUnwrap(store.reviewDraftForTracking).calendarSource)
    }

    @MainActor
    func testShareImportReplacesPreviousCalendarProvenance() async throws {
        let option = journeyOutboundOption()
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [
                .success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam]),
                .success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam]),
            ],
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [option])),
                .success(JourneySearchStoreFixtures.page(options: [option])),
            ]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request(source: source))
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertEqual(try XCTUnwrap(store.reviewDraftForTracking).calendarSource, source)

        await store.prefillTicketJourney(request(source: nil))
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertNil(try XCTUnwrap(store.reviewDraftForTracking).calendarSource)
    }

    @MainActor
    func testChangingResolvedRouteClearsCalendarProvenance() async throws {
        let imported = journeyOutboundOption()
        let lyon = JourneySearchStoreFixtures.place(id: "lyon", name: "Lyon")
        let manual = JourneySearchStoreFixtures.option(
            id: "manual", fingerprint: "manual", start: imported.startTime, end: imported.endTime,
            destination: lyon
        )
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [imported])),
                .success(JourneySearchStoreFixtures.page(options: [manual])),
            ]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request(source: source))
        await waitUntil { store.phase == .showingOutbound }

        store.setDestination(lyon)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(manual)

        XCTAssertNil(try XCTUnwrap(store.reviewDraftForTracking).calendarSource)
    }

    @MainActor
    func testCorrectingUnresolvedEndpointRetainsCalendarProvenance() async throws {
        let option = journeyOutboundOption()
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [.success([]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [.success(JourneySearchStoreFixtures.page(options: [option]))]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request(source: source))
        XCTAssertEqual(store.phase, .editing)
        XCTAssertNil(store.form.origin)

        store.setOrigin(JourneySearchStoreFixtures.paris)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)

        XCTAssertEqual(try XCTUnwrap(store.reviewDraftForTracking).calendarSource, source)
    }

    private func request(source: CalendarJourneySource?) -> TicketJourneySearchRequest {
        TicketJourneySearchRequest(
            originName: "Paris", destinationName: "Amsterdam",
            departureTime: "2026-07-24T06:25:00Z", trainNumber: "9315", calendarSource: source
        )
    }
}
