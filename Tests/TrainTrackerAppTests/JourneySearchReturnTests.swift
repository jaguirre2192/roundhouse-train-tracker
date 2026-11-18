import Foundation
import XCTest
@testable import TrainTracker

final class JourneySearchReturnTests: XCTestCase {
    @MainActor
    func testReturnSearchFailureMovesToTypedFailedPhaseWithoutClearingOutbound() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .failure(.unavailable),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .failed(.returnSearchUnavailable) }

        XCTAssertEqual(store.phase, .failed(.returnSearchUnavailable))
        XCTAssertEqual(store.selectedOutbound, outbound)
    }

    @MainActor
    func testReturnOptionsBeforeActualOutboundArrivalAreFiltered() async {
        let outbound = journeyOutboundOption(
            end: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
        )
        let early = journeyReturnOption(
            id: "early",
            fingerprint: "early",
            start: JourneySearchStoreFixtures.date("2026-07-24T09:59:59Z")
        )
        let valid = journeyReturnOption(
            id: "valid",
            fingerprint: "valid",
            start: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
        )
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [early, valid])),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
            )
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        XCTAssertEqual(store.visibleReturnOptions, [valid])
    }

    @MainActor
    func testReturnOptionsBeforeExpectedOutboundArrivalAreFiltered() async {
        let expectedArrival = JourneySearchStoreFixtures.date("2026-07-24T10:17:00Z")
        let outbound = JourneySearchStoreFixtures.option(
            id: "delayed-outbound",
            fingerprint: "delayed-outbound",
            start: JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z"),
            expectedArrival: expectedArrival
        )
        let tooEarly = journeyReturnOption(
            id: "too-early-for-expected-arrival",
            fingerprint: "too-early-for-expected-arrival",
            start: JourneySearchStoreFixtures.date("2026-07-24T10:15:00Z")
        )
        let valid = journeyReturnOption(
            id: "valid-at-expected-arrival",
            fingerprint: "valid-at-expected-arrival",
            start: expectedArrival
        )
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [tooEarly, valid])),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(returnTime: expectedArrival)
        )

        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }

        XCTAssertEqual(store.visibleReturnOptions, [valid])
    }

    @MainActor
    func testExpectedOutboundArrivalDefinesFiveMinuteRecoveryBoundary() async {
        let outbound = JourneySearchStoreFixtures.option(
            id: "delayed-outbound",
            fingerprint: "delayed-outbound",
            start: JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z"),
            expectedArrival: JourneySearchStoreFixtures.date("2026-07-24T10:17:00Z")
        )
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(pages: [
                .success(JourneySearchStoreFixtures.page(options: [outbound])),
            ]),
            form: JourneySearchStoreFixtures.form(
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T10:15:00Z")
            )
        )

        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)

        XCTAssertEqual(
            store.earliestValidReturnTime,
            JourneySearchStoreFixtures.date("2026-07-24T10:20:00Z")
        )
    }

    @MainActor
    func testNoReturnActionsNeverSilentlyToggleReturn() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [])),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }

        store.editReturn()
        XCTAssertTrue(store.form.returnEnabled)
        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertEqual(store.phase, .showingReturn)

        store.continueAsOneWay()
        XCTAssertTrue(store.form.returnEnabled)
        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertEqual(store.phase, .reviewing)
    }

    @MainActor
    func testEarlierReturnRequiresExplicitFiveMinuteAdjustmentAcceptance() async {
        let outbound = journeyOutboundOption(
            end: JourneySearchStoreFixtures.date("2026-07-24T10:02:01Z")
        )
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [])),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z")
            )
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)

        XCTAssertEqual(store.earliestValidReturnTime, JourneySearchStoreFixtures.date("2026-07-24T10:05:00Z"))
        let requestsBeforeAcceptance = await client.journeyRequests
        XCTAssertEqual(requestsBeforeAcceptance.count, 1)
        store.acceptAdjustedReturnSearch()
        await waitUntil { store.phase == .showingReturn }

        let requests = await client.journeyRequests
        XCTAssertEqual(store.form.returnTime, JourneySearchStoreFixtures.date("2026-07-24T10:05:00Z"))
        XCTAssertEqual(requests.last?.requestedTime, store.form.returnTime)
    }

    @MainActor
    func testEditingInsteadOfAcceptingAdjustmentPreservesOutboundAndOriginalReturn() async {
        let outbound = journeyOutboundOption(
            end: JourneySearchStoreFixtures.date("2026-07-24T10:02:01Z")
        )
        let requestedReturn = JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z")
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(returnTime: requestedReturn)
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        XCTAssertNotNil(store.earliestValidReturnTime)

        store.editReturn()

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertTrue(store.form.returnEnabled)
        XCTAssertEqual(store.form.returnTime, requestedReturn)
        XCTAssertNil(store.earliestValidReturnTime)
        XCTAssertEqual(store.phase, .showingReturn)
        let requests = await client.journeyRequests
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testEditedReturnBeforeOutboundArrivalRequiresAdjustmentBeforeTransport() async {
        let outbound = journeyOutboundOption(
            end: JourneySearchStoreFixtures.date("2026-07-24T10:02:01Z")
        )
        let returnOption = journeyReturnOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [returnOption])),
            .success(JourneySearchStoreFixtures.page(options: [])),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.returnPage != nil }
        store.selectReturn(returnOption)

        store.setReturnTime(JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z"))
        store.searchReturn()
        await Task.yield()

        XCTAssertEqual(
            store.earliestValidReturnTime,
            JourneySearchStoreFixtures.date("2026-07-24T10:05:00Z")
        )
        XCTAssertEqual(store.phase, .showingReturn)
        let requests = await client.journeyRequests
        XCTAssertEqual(requests.count, 2)
    }

    @MainActor
    func testFiveMinuteCeilingKeepsExactBoundary() async {
        let boundary = JourneySearchStoreFixtures.date("2026-07-24T10:05:00Z")
        let outbound = journeyOutboundOption(end: boundary)
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z")
            )
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        XCTAssertEqual(store.earliestValidReturnTime, boundary)
    }

    @MainActor
    func testFiveMinuteCeilingUsesReturnCalendarAcrossDSTGap() async {
        let losAngeles = JourneySearchStoreFixtures.place(
            id: "us:transitous:los-angeles",
            name: "Los Angeles",
            country: "US",
            timeZone: "America/Los_Angeles"
        )
        let outbound = JourneySearchStoreFixtures.option(
            id: "dst",
            fingerprint: "dst",
            start: JourneySearchStoreFixtures.date("2026-03-08T08:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-03-08T09:59:01Z"),
            destination: losAngeles
        )
        let form = JourneySearchFormState(
            origin: JourneySearchStoreFixtures.paris,
            destination: losAngeles,
            outboundTime: JourneySearchStoreFixtures.date("2026-03-08T08:00:00Z"),
            returnEnabled: true,
            returnTime: JourneySearchStoreFixtures.date("2026-03-08T09:00:00Z")
        )
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(pages: [
                .success(JourneySearchStoreFixtures.page(options: [outbound])),
            ]),
            form: form
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        XCTAssertEqual(store.earliestValidReturnTime, JourneySearchStoreFixtures.date("2026-03-08T10:00:00Z"))
    }

    @MainActor
    func testOpaqueSignedCursorsReplaceOutboundAndReturnPages() async {
        let outbound = journeyOutboundOption()
        let laterOutbound = journeyOutboundOption(id: "later", fingerprint: "later")
        let returnOption = journeyReturnOption()
        let earlierReturn = journeyReturnOption(id: "earlier", fingerprint: "earlier")
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound], next: "out.next.sig")),
            .success(JourneySearchStoreFixtures.page(options: [laterOutbound], previous: "out.prev.sig")),
            .success(JourneySearchStoreFixtures.page(options: [returnOption], previous: "return.prev.sig")),
            .success(JourneySearchStoreFixtures.page(options: [earlierReturn], next: "return.next.sig")),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.outboundPage?.nextCursor != nil }
        store.loadLaterOutbound()
        await waitUntil { store.outboundPage?.previousCursor != nil }
        store.selectOutbound(laterOutbound)
        await waitUntil { store.returnPage?.previousCursor != nil }
        store.loadEarlierReturn()
        await waitUntil { store.returnPage?.nextCursor != nil }

        let cursors = await client.journeyRequests.map { $0.cursor }
        XCTAssertEqual(cursors, [nil, "out.next.sig", nil, "return.prev.sig"])
        XCTAssertEqual(store.returnPage?.options, [earlierReturn])
    }

    @MainActor
    func testFilteredEmptyReturnPageLoadsSignedNextWindowAndReplacesWithValidResults() async {
        let outbound = journeyOutboundOption(
            end: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
        )
        let invalidReturn = journeyReturnOption(
            id: "invalid-return",
            fingerprint: "invalid-return",
            start: JourneySearchStoreFixtures.date("2026-07-24T09:59:00Z")
        )
        let validReturn = journeyReturnOption(
            id: "valid-return",
            fingerprint: "valid-return",
            start: JourneySearchStoreFixtures.date("2026-07-24T10:30:00Z")
        )
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(
                options: [invalidReturn],
                next: "signed.next.return.window"
            )),
            .success(JourneySearchStoreFixtures.page(
                options: [validReturn],
                previous: "signed.previous.return.window"
            )),
        ])
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
            )
        )

        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.returnPage?.nextCursor != nil }

        XCTAssertTrue(store.visibleReturnOptions.isEmpty)
        store.loadLaterReturn()
        await waitUntil { store.returnPage?.previousCursor != nil }

        let requests = await client.journeyRequests
        XCTAssertEqual(requests.map(\.cursor), [nil, nil, "signed.next.return.window"])
        XCTAssertEqual(store.visibleReturnOptions, [validReturn])
    }

    @MainActor
    func testDirectOnlyKeepsOneWayContinuationInReview() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [])),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        store.continueAsOneWay()

        store.setDirectOnly(true)

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertEqual(store.phase, .reviewing)
    }

    @MainActor
    func testDirectOnlyAfterFailedReturnSearchKeepsFailure() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .failure(.unavailable),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .failed(.returnSearchUnavailable) }

        store.setDirectOnly(true)

        XCTAssertEqual(store.phase, .failed(.returnSearchUnavailable))
        XCTAssertNil(store.returnPage)
    }

    @MainActor
    func testDirectOnlyInvalidatesStaleReturnPageWhenOutboundIsRemoved() async {
        let outbound = JourneySearchStoreFixtures.option(
            id: "connecting-outbound",
            fingerprint: "connecting-outbound",
            start: JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T09:50:00Z"),
            transferCount: 1
        )
        let staleReturn = journeyReturnOption(id: "stale-return", fingerprint: "stale-return")
        let client = StaleReturnJourneySearchClient(
            outboundPage: JourneySearchStoreFixtures.page(options: [outbound])
        )
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await client.waitForReturnRequest()

        store.setDirectOnly(true)
        await client.resumeReturn(with: JourneySearchStoreFixtures.page(options: [staleReturn]))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(store.selectedOutbound)
        XCTAssertNil(store.returnPage)
        XCTAssertEqual(store.phase, .showingOutbound)
    }

    @MainActor
    func testSelectingConflictingOutboundInvalidatesPriorReturnPage() async {
        let outboundA = journeyOutboundOption(
            id: "outbound-a",
            fingerprint: "outbound-a",
            end: JourneySearchStoreFixtures.date("2026-07-24T09:50:00Z")
        )
        let outboundB = journeyOutboundOption(
            id: "outbound-b",
            fingerprint: "outbound-b",
            end: JourneySearchStoreFixtures.date("2026-07-24T10:02:01Z")
        )
        let staleReturn = journeyReturnOption(id: "stale-return", fingerprint: "stale-return")
        let client = StaleReturnJourneySearchClient(
            outboundPage: JourneySearchStoreFixtures.page(options: [outboundA, outboundB])
        )
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
            )
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outboundA)
        await client.waitForReturnRequest()

        store.selectOutbound(outboundB)
        await client.resumeReturn(with: JourneySearchStoreFixtures.page(options: [staleReturn]))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.selectedOutbound, outboundB)
        XCTAssertNil(store.returnPage)
        XCTAssertEqual(
            store.earliestValidReturnTime,
            JourneySearchStoreFixtures.date("2026-07-24T10:05:00Z")
        )
        XCTAssertEqual(store.phase, .showingReturn)
    }
}
