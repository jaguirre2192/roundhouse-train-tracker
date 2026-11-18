import XCTest
@testable import TrainTracker

final class JourneySearchStoreTests: XCTestCase {
    @MainActor
    func testTicketJourneyPrefillResolvesStationsAndStartsOutboundSearch() async {
        let london = JourneySearchStoreFixtures.place(
            id: "eu:transitous:gb-london-st-pancras",
            name: "London St Pancras International",
            kind: .station,
            country: "GB",
            timeZone: "Europe/London"
        )
        let parisNord = JourneySearchStoreFixtures.place(
            id: "eu:transitous:fr-paris-nord",
            name: "Paris Gare du Nord",
            kind: .station,
            country: "FR",
            timeZone: "Europe/Paris"
        )
        let client = ScriptedJourneySearchClient(
            places: [.success([london]), .success([parisNord])],
            pages: [.success(JourneySearchStoreFixtures.page(options: []))]
        )
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchFormState()
        )

        await store.prefillTicketJourney(TicketJourneySearchRequest(
            originName: "London St Pancras",
            destinationName: "Paris Gare du Nord",
            departureTime: "2026-08-14T15:09:00+02:00",
            trainNumber: "9032"
        ))
        await waitUntil { store.phase == .showingOutbound }

        XCTAssertEqual(store.form.origin, london)
        XCTAssertEqual(store.form.destination, parisNord)
        XCTAssertFalse(store.form.returnEnabled)
        XCTAssertEqual(
            store.form.outboundTime,
            ISO8601DateFormatter().date(from: "2026-08-14T15:09:00+02:00")
        )
        let request = await client.journeyRequests.first
        XCTAssertEqual(request?.originID, london.id)
        XCTAssertEqual(request?.destinationID, parisNord.id)
    }

    @MainActor
    func testTicketJourneyPrefillLeavesCorrectableFormWhenOneStationCannotResolve() async {
        let parisNord = JourneySearchStoreFixtures.place(
            id: "eu:transitous:fr-paris-nord",
            name: "Paris Gare du Nord",
            kind: .station,
            country: "FR",
            timeZone: "Europe/Paris"
        )
        let client = ScriptedJourneySearchClient(places: [
            .success([]),
            .success([parisNord]),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchFormState()
        )

        await store.prefillTicketJourney(TicketJourneySearchRequest(
            originName: "Unresolvable Origin",
            destinationName: "Paris Gare du Nord",
            departureTime: "2026-08-14",
            trainNumber: nil
        ))

        XCTAssertEqual(store.phase, .editing)
        XCTAssertNil(store.form.origin)
        XCTAssertEqual(store.form.destination, parisNord)
        let journeyRequests = await client.journeyRequests
        XCTAssertTrue(journeyRequests.isEmpty)
    }

    @MainActor
    func testTicketJourneyPrefillWithoutDateDoesNotSearchToday() async {
        let london = JourneySearchStoreFixtures.place(
            id: "eu:transitous:gb-london-st-pancras",
            name: "London St Pancras International",
            kind: .station,
            country: "GB",
            timeZone: "Europe/London"
        )
        let parisNord = JourneySearchStoreFixtures.place(
            id: "eu:transitous:fr-paris-nord",
            name: "Paris Gare du Nord",
            kind: .station,
            country: "FR",
            timeZone: "Europe/Paris"
        )
        let client = ScriptedJourneySearchClient(places: [
            .success([london]),
            .success([parisNord]),
        ])
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())

        await store.prefillTicketJourney(TicketJourneySearchRequest(
            originName: "London St Pancras",
            destinationName: "Paris Gare du Nord",
            departureTime: nil,
            trainNumber: "9032"
        ))

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.form.origin, london)
        XCTAssertEqual(store.form.destination, parisNord)
        XCTAssertEqual(store.preferredTrainNumber, "9032")
        let journeyRequests = await client.journeyRequests
        XCTAssertTrue(journeyRequests.isEmpty)
    }

    @MainActor
    func testTicketTrainNumberIsRankedFirstWithoutDiscardingOtherResults() async {
        let other = JourneySearchStoreFixtures.option(
            id: "other",
            fingerprint: "other",
            start: JourneySearchStoreFixtures.date("2026-08-14T09:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-08-14T11:00:00Z"),
            trainNumber: "9010"
        )
        let ticketTrain = JourneySearchStoreFixtures.option(
            id: "ticket-train",
            fingerprint: "ticket-train",
            start: JourneySearchStoreFixtures.date("2026-08-14T10:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-08-14T12:00:00Z"),
            trainNumber: "9032"
        )
        let client = ScriptedJourneySearchClient(
            places: [
                .success([JourneySearchStoreFixtures.paris]),
                .success([JourneySearchStoreFixtures.amsterdam]),
            ],
            pages: [.success(JourneySearchStoreFixtures.page(options: [other, ticketTrain]))]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())

        await store.prefillTicketJourney(TicketJourneySearchRequest(
            originName: "Paris",
            destinationName: "Amsterdam",
            departureTime: "2026-08-14T10:00:00Z",
            trainNumber: "90 32"
        ))
        await waitUntil { store.phase == .showingOutbound }

        XCTAssertEqual(store.visibleOutboundOptions.map(\.id), ["ticket-train", "other"])
    }

    @MainActor
    func testRoundTripTransitionsFromEditingThroughOutboundReturnAndReview() async {
        let outbound = journeyOutboundOption()
        let returnOption = journeyReturnOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [returnOption])),
        ])
        let store = makeJourneySearchStore(client: client)
        XCTAssertEqual(store.phase, .editing)

        store.searchOutbound()
        XCTAssertEqual(store.phase, .loadingOutbound)
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        XCTAssertEqual(store.phase, .loadingReturn)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(returnOption)

        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertEqual(store.selectedReturn, returnOption)
        let requests = await client.journeyRequests
        XCTAssertEqual(requests[1].originID, JourneySearchStoreFixtures.amsterdam.id)
        XCTAssertEqual(requests[1].destinationID, JourneySearchStoreFixtures.paris.id)
    }

    @MainActor
    func testOneWaySelectionMovesDirectlyToReview() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(returnEnabled: false)
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)

        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertNil(store.selectedReturn)
    }

    @MainActor
    func testOutboundFailureMovesToTypedFailedPhase() async {
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(pages: [.failure(.unavailable)])
        )
        store.searchOutbound()
        await waitUntil { store.phase == .failed(.outboundSearchUnavailable) }
        XCTAssertEqual(store.phase, .failed(.outboundSearchUnavailable))
        XCTAssertEqual(store.journeyFailureReason, .serviceUnavailable)
    }

    @MainActor
    func testCancellationErrorDoesNotBecomeVisibleFailure() async {
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(pages: [.failure(.cancelled)])
        )
        store.searchOutbound()
        await waitUntil { !store.isJourneyTaskActive }
        XCTAssertEqual(store.phase, .loadingOutbound)
    }

    @MainActor
    func testReplacementSuppressesStaleJourneyResultWhenDependencyIgnoresCancellation() async {
        let stale = JourneySearchStoreFixtures.page(options: [
            journeyOutboundOption(id: "stale", fingerprint: "stale"),
        ])
        let freshOption = journeyOutboundOption(id: "fresh", fingerprint: "fresh")
        let fresh = JourneySearchStoreFixtures.page(options: [freshOption])
        let client = StaleJourneySearchClient(replacementPage: fresh)
        let store = makeJourneySearchStore(client: client)

        store.searchOutbound()
        await client.waitForFirstRequest()
        store.setOutboundTime(JourneySearchStoreFixtures.date("2026-07-24T07:00:00Z"))
        store.searchOutbound()
        await waitUntil { store.outboundPage == fresh }
        await client.resumeFirst(with: stale)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.outboundPage, fresh)
        XCTAssertEqual(store.phase, .showingOutbound)
    }

    @MainActor
    func testPlaceLookupUsesIndependentTaskWithoutChangingJourneyPhase() async {
        let client = ScriptedJourneySearchClient(places: [
            .success([JourneySearchStoreFixtures.paris]),
        ])
        let store = makeJourneySearchStore(client: client)
        store.lookupPlaces(query: "Paris", limit: 20)

        XCTAssertTrue(store.isPlaceLookupTaskActive)
        XCTAssertEqual(store.phase, .editing)
        await waitUntil { store.placeResults == [JourneySearchStoreFixtures.paris] }

        XCTAssertFalse(store.isPlaceLookupTaskActive)
        XCTAssertFalse(store.placeLookupFailed)
        let request = await client.placeRequests.first
        XCTAssertEqual(request?.query, "Paris")
        XCTAssertEqual(request?.limit, 20)
    }

    @MainActor
    func testReplacementSuppressesStalePlaceLookup() async {
        let client = StalePlaceJourneySearchClient(
            replacementPlaces: [JourneySearchStoreFixtures.amsterdam]
        )
        let store = makeJourneySearchStore(client: client)
        store.lookupPlaces(query: "Pa")
        await client.waitForFirstRequest()
        store.lookupPlaces(query: "Am")
        await waitUntil { store.placeResults == [JourneySearchStoreFixtures.amsterdam] }
        await client.resumeFirst(with: [JourneySearchStoreFixtures.paris])
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.placeResults, [JourneySearchStoreFixtures.amsterdam])
        XCTAssertEqual(store.phase, .editing)
    }

    @MainActor
    func testPlaceLookupCancellationIsNotShownAsFailure() async {
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(places: [.failure(.cancelled)])
        )
        store.lookupPlaces(query: "Paris")
        await waitUntil { !store.isPlaceLookupTaskActive }
        XCTAssertFalse(store.placeLookupFailed)
    }

    @MainActor
    func testSelectingAPlaceCancelsTheObsoleteLookup() async {
        let client = StalePlaceJourneySearchClient(
            replacementPlaces: [JourneySearchStoreFixtures.amsterdam]
        )
        let store = makeJourneySearchStore(client: client)
        store.lookupPlaces(query: "Pa")
        await client.waitForFirstRequest()

        store.setOrigin(JourneySearchStoreFixtures.place(id: "lyon", name: "Lyon"))
        XCTAssertFalse(store.isPlaceLookupTaskActive)
        await client.resumeFirst(with: [JourneySearchStoreFixtures.amsterdam])
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(store.placeResults.isEmpty)
    }
}
