import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneySearchImportedReviewTests: XCTestCase {
    @MainActor
    func testOptInOpensReviewWithoutResolvingOrSavingAndKeepsCalendarSource() async throws {
        let option = journeyOutboundOption()
        let client = client(pages: [page(option)])
        let tracker = RecordingJourneyPlanTracker()
        let store = makeJourneySearchStore(client: client, tracker: tracker, form: JourneySearchFormState())

        await store.prefillTicketJourney(request())
        await waitUntil { store.phase == .reviewing }

        XCTAssertEqual(store.selectedOutbound, option)
        XCTAssertTrue(store.canChooseAnotherImportedTrain)
        XCTAssertEqual(try XCTUnwrap(store.reviewDraftForTracking).calendarSource, source)
        XCTAssertTrue(tracker.calls.isEmpty)
        let resolutionRequests = await client.resolutionRequests
        XCTAssertTrue(resolutionRequests.isEmpty)
    }

    @MainActor
    func testChoosingAnotherUsesFetchedPageAndNeverRepeatsAutoSelection() async {
        let option = journeyOutboundOption()
        let originalPage = JourneySearchStoreFixtures.page(options: [option], next: "later")
        let client = client(pages: [originalPage, page(option), page(option)])
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request())
        await waitUntil { store.phase == .reviewing }

        store.chooseAnotherImportedTrain()
        XCTAssertEqual(store.phase, .showingOutbound)
        XCTAssertEqual(store.outboundPage, originalPage)
        XCTAssertNil(store.selectedOutbound)
        XCTAssertFalse(store.canChooseAnotherImportedTrain)
        let requestsBeforePaging = await client.journeyRequests
        XCTAssertEqual(requestsBeforePaging.count, 1)

        store.loadLaterOutbound()
        await waitUntil { store.phase == .showingOutbound }
        XCTAssertNil(store.selectedOutbound)
        store.editSearch()
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        XCTAssertNil(store.selectedOutbound)
        XCTAssertFalse(store.canChooseAnotherImportedTrain)
    }

    @MainActor
    func testDefaultRequestAndDateOnlyImportStayInResults() async {
        for value in [request(prefersDirectReview: false), request(departureTime: "2026-07-24")] {
            let store = makeJourneySearchStore(client: client(pages: [page(journeyOutboundOption())]), form: JourneySearchFormState())
            await store.prefillTicketJourney(value)
            await waitUntil { store.phase == .showingOutbound }
            XCTAssertNil(store.selectedOutbound)
            XCTAssertFalse(store.canChooseAnotherImportedTrain)
        }
    }

    @MainActor
    func testAmbiguousOrUnmatchedImportShowsHelpfulResultsMessage() async {
        let option = journeyOutboundOption()
        let ambiguous = journeyOutboundOption(id: "alternative", fingerprint: "alternative")
        for options in [[option, ambiguous], [JourneySearchStoreFixtures.option(
            id: "wrong-number", fingerprint: "wrong-number", start: option.startTime, end: option.endTime, trainNumber: "9999"
        )]] {
            let store = makeJourneySearchStore(
                client: client(pages: [JourneySearchStoreFixtures.page(options: options)]), form: JourneySearchFormState()
            )
            await store.prefillTicketJourney(request())
            await waitUntil { store.phase == .showingOutbound }
            XCTAssertNil(store.selectedOutbound)
            XCTAssertNotNil(store.importedReviewMessage)
        }
    }

    @MainActor
    func testUnresolvedOrIdenticalEndpointsCannotAutoSelect() async {
        let option = journeyOutboundOption()
        for places in [[RailPlace](), [JourneySearchStoreFixtures.paris]] {
            let scripted = ScriptedJourneySearchClient(
                places: [.success([JourneySearchStoreFixtures.paris]), .success(places)], pages: [.success(page(option))]
            )
            let store = makeJourneySearchStore(client: scripted, form: JourneySearchFormState())
            let value = TicketJourneySearchRequest(
                originName: "Paris", destinationName: places.isEmpty ? "Unknown" : "Paris",
                departureTime: "2026-07-24T06:25:00Z", trainNumber: "9315", prefersDirectReview: true
            )
            await store.prefillTicketJourney(value)
            XCTAssertEqual(store.phase, .editing)
            XCTAssertNil(store.selectedOutbound)
            let requests = await scripted.journeyRequests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    @MainActor
    func testManualEndpointCorrectionInvalidatesStaleImportedPlaceResponse() async {
        let client = StalePlaceJourneySearchClient(replacementPlaces: [JourneySearchStoreFixtures.amsterdam])
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        let task = Task { await store.prefillTicketJourney(request()) }
        await client.waitForFirstRequest()
        let lyon = JourneySearchStoreFixtures.place(id: "lyon", name: "Lyon")
        store.setOrigin(lyon)
        store.setDestination(JourneySearchStoreFixtures.amsterdam)
        await client.resumeFirst(with: [JourneySearchStoreFixtures.paris])
        await task.value

        XCTAssertEqual(store.form.origin, lyon)
        XCTAssertEqual(store.phase, .editing)
        XCTAssertNil(store.outboundPage)
        XCTAssertNil(store.selectedOutbound)
    }

    @MainActor
    func testManualSearchInvalidatesStaleImportedJourneyResponse() async {
        let imported = journeyOutboundOption()
        let manual = journeyOutboundOption(id: "manual", fingerprint: "manual")
        let client = SuspendedImportedJourneyClient(replacementPage: page(manual))
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request())
        await client.waitForFirstRequest()
        store.editSearch()
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        await client.resumeFirst(with: page(imported))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.outboundPage?.options, [manual])
        XCTAssertEqual(store.phase, .showingOutbound)
        XCTAssertNil(store.selectedOutbound)
    }

    private var source: CalendarJourneySource { CalendarJourneySource(eventKey: "event", revision: "revision") }

    private func request(
        departureTime: String? = "2026-07-24T06:25:00Z", prefersDirectReview: Bool = true
    ) -> TicketJourneySearchRequest {
        TicketJourneySearchRequest(
            originName: "Paris", destinationName: "Amsterdam", departureTime: departureTime,
            trainNumber: "9315", calendarSource: source, prefersDirectReview: prefersDirectReview
        )
    }

    private func page(_ option: JourneyOption) -> JourneySearchPage {
        JourneySearchStoreFixtures.page(options: [option])
    }

    private func client(pages: [JourneySearchPage]) -> ScriptedJourneySearchClient {
        ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: pages.map { .success($0) }
        )
    }
}

private actor SuspendedImportedJourneyClient: JourneySearching {
    let replacementPage: JourneySearchPage
    private var continuation: CheckedContinuation<JourneySearchPage, Never>?
    private var requestCount = 0

    init(replacementPage: JourneySearchPage) { self.replacementPage = replacementPage }
    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] {
        [JourneySearchStoreFixtures.paris, JourneySearchStoreFixtures.amsterdam]
    }
    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        requestCount += 1
        if requestCount == 1 { return await withCheckedContinuation { continuation = $0 } }
        return replacementPage
    }
    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        JourneyPlanResolution(directions: [])
    }
    func waitForFirstRequest() async {
        while continuation == nil { await Task.yield() }
    }
    func resumeFirst(with page: JourneySearchPage) {
        continuation?.resume(returning: page)
        continuation = nil
    }
}
