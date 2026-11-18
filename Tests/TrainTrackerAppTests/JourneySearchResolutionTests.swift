import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class JourneySearchResolutionTests: XCTestCase {
    @MainActor
    func testResolutionTransitionsThroughResolvingReviewAndCompletion() async {
        let outbound = journeyOutboundOption()
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [trip]
        )
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(resolution)]
        )
        let tracker = RecordingJourneyPlanTracker()
        let store = await prepareOneWayJourneyReview(
            client: client,
            tracker: tracker,
            outbound: outbound
        )

        store.resolveSelection()
        XCTAssertEqual(store.phase, .resolving)
        await waitUntil { store.resolvedPlan == resolution }
        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertTrue(store.canTrackAvailableTrips)
        XCTAssertEqual(store.availableTripCount, 1)
        store.trackResolvedPlan()

        guard case let .completed(planID) = store.phase else {
            return XCTFail("Expected tracking completion")
        }
        XCTAssertEqual(planID, tracker.calls.first?.draft.id)
        XCTAssertEqual(tracker.calls.first?.resolution, resolution)
    }

    @MainActor
    func testPartialResolutionRequiresConsentAfterListingEveryFailure() async {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]],
            outboundFailures: [
                ("missing-leg", JourneySearchStoreFixtures.failure(
                    code: .notFound,
                    message: "Train could not be matched"
                )),
                ("provider-leg", JourneySearchStoreFixtures.failure(
                    code: .providerUnavailable,
                    message: "Provider unavailable"
                )),
            ]
        )
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(resolution)]
        )
        let store = await prepareOneWayJourneyReview(client: client, outbound: outbound)

        store.resolveSelection()
        await waitUntil { store.resolvedPlan != nil }
        XCTAssertEqual(store.resolutionFailures.map(\.segmentID), ["missing-leg", "provider-leg"])
        XCTAssertFalse(store.canTrackAvailableTrips)
        store.setAvailableSubsetConfirmed(true)

        XCTAssertTrue(store.availableSubsetConfirmed)
        XCTAssertTrue(store.canTrackAvailableTrips)
        store.setAvailableSubsetConfirmed(false)
        XCTAssertFalse(store.availableSubsetConfirmed)
        XCTAssertFalse(store.canTrackAvailableTrips)
    }

    @MainActor
    func testKnownUntrackableReturnMakesMixedSelectionPartialAndRequiresConsent() async {
        let outbound = journeyOutboundOption()
        let returnOption = journeyReturnOption(
            isTrackable: false,
            untrackableReason: "No stable train identity"
        )
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]],
            returnOption: returnOption,
            returnTrips: []
        )
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [outbound])),
                .success(JourneySearchStoreFixtures.page(options: [returnOption])),
            ],
            resolutions: [.success(resolution)]
        )
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(returnOption)

        store.resolveSelection()
        await waitUntil { store.resolvedPlan != nil }

        XCTAssertEqual(store.resolutionSummary?.state, .partial)
        XCTAssertEqual(store.resolutionFailures.map(\.segmentID), ["return-rail"])
        XCTAssertEqual(store.resolutionFailures.map(\.message), ["No stable train identity"])
        XCTAssertFalse(store.canTrackAvailableTrips)
        store.setAvailableSubsetConfirmed(true)
        XCTAssertTrue(store.canTrackAvailableTrips)
    }

    @MainActor
    func testAllKnownUntrackableSelectionIsNoneAndListsStableReason() async {
        let outbound = journeyOutboundOption(
            isTrackable: false,
            untrackableReason: "Operator does not expose a stable trip"
        )
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: []
        )
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(resolution)]
        )
        let store = await prepareOneWayJourneyReview(client: client, outbound: outbound)

        store.resolveSelection()
        await waitUntil { store.resolvedPlan != nil }
        store.setAvailableSubsetConfirmed(true)

        XCTAssertEqual(
            store.resolutionSummary?.state,
            JourneyResolutionSummary.State.none
        )
        XCTAssertEqual(store.resolutionFailures.map(\.segmentID), ["outbound-rail"])
        XCTAssertEqual(
            store.resolutionFailures.map(\.message),
            ["Operator does not expose a stable trip"]
        )
        XCTAssertFalse(store.availableSubsetConfirmed)
        XCTAssertFalse(store.canTrackAvailableTrips)
    }

    @MainActor
    func testAllFailuresCannotBeConfirmedOrTracked() async {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [],
            outboundFailures: [("only-leg", JourneySearchStoreFixtures.failure(
                code: .notFound,
                message: "Unavailable"
            ))]
        )
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(resolution)]
        )
        let tracker = RecordingJourneyPlanTracker()
        let store = await prepareOneWayJourneyReview(
            client: client,
            tracker: tracker,
            outbound: outbound
        )
        store.resolveSelection()
        await waitUntil { store.resolvedPlan != nil }
        store.confirmAvailableSubset()
        store.trackResolvedPlan()

        XCTAssertEqual(store.resolutionFailures.map(\.segmentID), ["only-leg"])
        XCTAssertFalse(store.availableSubsetConfirmed)
        XCTAssertFalse(store.canTrackAvailableTrips)
        XCTAssertTrue(tracker.calls.isEmpty)
        XCTAssertEqual(store.phase, .reviewing)
    }

    @MainActor
    func testResolutionFailureIsTypedWhileCancellationChangesNoState() async {
        let outbound = journeyOutboundOption()
        let failedClient = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.failure(.unavailable)]
        )
        let failedStore = await prepareOneWayJourneyReview(client: failedClient, outbound: outbound)
        failedStore.resolveSelection()
        await waitUntil { failedStore.phase == .failed(.resolutionUnavailable) }

        let cancelledClient = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.failure(.cancelled)]
        )
        let cancelledStore = await prepareOneWayJourneyReview(
            client: cancelledClient,
            outbound: outbound
        )
        cancelledStore.resolveSelection()
        await waitUntil { !cancelledStore.isJourneyTaskActive }

        XCTAssertEqual(failedStore.phase, .failed(.resolutionUnavailable))
        XCTAssertEqual(cancelledStore.phase, .resolving)
    }

    @MainActor
    func testDirectOnlyInvalidatesStaleResolutionWhenOutboundIsRemoved() async {
        let outbound = JourneySearchStoreFixtures.option(
            id: "connecting-outbound",
            fingerprint: "connecting-outbound",
            start: JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T09:50:00Z"),
            transferCount: 1
        )
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
        )
        let client = StaleResolutionJourneySearchClient(
            outboundPage: JourneySearchStoreFixtures.page(options: [outbound])
        )
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(returnEnabled: false)
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        store.resolveSelection()
        await client.waitForResolutionRequest()

        store.setDirectOnly(true)
        await client.resumeResolution(with: resolution)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(store.selectedOutbound)
        XCTAssertNil(store.resolvedPlan)
        XCTAssertFalse(store.canTrackAvailableTrips)
        XCTAssertEqual(store.phase, .showingOutbound)
    }

    @MainActor
    func testTrackingFailureKeepsResolvedReviewStateForRetry() async {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
        )
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(resolution)]
        )
        let tracker = RecordingJourneyPlanTracker()
        tracker.shouldFail = true
        let store = await prepareOneWayJourneyReview(
            client: client,
            tracker: tracker,
            outbound: outbound
        )
        store.resolveSelection()
        await waitUntil { store.canTrackAvailableTrips }
        XCTAssertFalse(store.trackResolvedPlan())

        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertTrue(store.trackingFailed)
        XCTAssertEqual(store.resolvedPlan, resolution)

        tracker.shouldFail = false
        XCTAssertTrue(store.trackResolvedPlan())
        guard case .completed = store.phase else { return XCTFail("Expected retry success") }
        XCTAssertFalse(store.trackingFailed)
        XCTAssertEqual(tracker.calls.count, 2)
    }

    @MainActor
    func testSuccessfulTrackingCanCompleteOnlyOnceAcrossSequentialCalls() async {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
        )
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(resolution)]
        )
        let tracker = RecordingJourneyPlanTracker()
        let store = await prepareOneWayJourneyReview(
            client: client,
            tracker: tracker,
            outbound: outbound
        )
        store.resolveSelection()
        await waitUntil { store.canTrackAvailableTrips }

        let first = store.trackResolvedPlan()
        let second = store.trackResolvedPlan()

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(tracker.calls.count, 1)
        guard case .completed = store.phase else { return XCTFail("Expected completion") }
    }

    @MainActor
    func testConcurrentTrackingRequestsPersistAndSucceedOnlyOnce() async {
        let outbound = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
        )
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(resolution)]
        )
        let tracker = RecordingJourneyPlanTracker()
        let store = await prepareOneWayJourneyReview(
            client: client,
            tracker: tracker,
            outbound: outbound
        )
        store.resolveSelection()
        await waitUntil { store.canTrackAvailableTrips }

        let first = Task { @MainActor in store.trackResolvedPlan() }
        let second = Task { @MainActor in store.trackResolvedPlan() }
        let results = [await first.value, await second.value]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(tracker.calls.count, 1)
        guard case .completed = store.phase else { return XCTFail("Expected completion") }
    }

    @MainActor
    func testResolutionRetryIgnoresTheStaleFirstResponse() async {
        let outbound = journeyOutboundOption()
        let stale = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
        )
        let current = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[1]]
        )
        let client = RetryingResolutionJourneySearchClient(
            outboundPage: JourneySearchStoreFixtures.page(options: [outbound])
        )
        let store = makeJourneySearchStore(
            client: client,
            form: JourneySearchStoreFixtures.form(returnEnabled: false)
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)

        store.resolveSelection()
        await client.waitForRequest(count: 1)
        store.resolveSelection()
        await client.waitForRequest(count: 2)
        await client.resumeRequest(at: 1, with: current)
        await waitUntil { store.resolvedPlan == current }
        await client.resumeRequest(at: 0, with: stale)
        await Task.yield()

        XCTAssertEqual(store.resolvedPlan, current)
        XCTAssertEqual(store.phase, .reviewing)
    }

    @MainActor
    func testRoundTripResolutionAndRetryEachUseOneCombinedRequest() async {
        let outbound = journeyOutboundOption()
        let returnOption = journeyReturnOption()
        let trips = JourneyPlanTestFixtures.makeTrips()
        let resolution = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: [trips[0]],
            returnOption: returnOption,
            returnTrips: [trips[1]]
        )
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [outbound])),
                .success(JourneySearchStoreFixtures.page(options: [returnOption])),
            ],
            resolutions: [.success(resolution), .success(resolution)]
        )
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(returnOption)

        store.resolveSelection()
        await waitUntil { store.resolvedPlan != nil }
        store.resolveSelection()
        await waitUntil { store.phase == .reviewing && !store.isJourneyTaskActive }

        let requests = await client.resolutionRequests
        XCTAssertEqual(requests, [
            [outbound.trackingToken, returnOption.trackingToken],
            [outbound.trackingToken, returnOption.trackingToken],
        ])
    }

    @MainActor
    func testExpiredOneWayRerunsExactCriteriaAndRetriesWithFreshToken() async {
        let (old, fresh) = tokenRefreshOptions(fingerprint: "stable")
        let recovered = JourneySearchStoreFixtures.resolution(
            outbound: fresh,
            outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]
        )
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [old])),
                .success(JourneySearchStoreFixtures.page(options: [fresh])),
            ],
            resolutions: [.failure(.trackingTokenExpired), .success(recovered)]
        )
        let store = await prepareOneWayJourneyReview(client: client, outbound: old)
        store.resolveSelection()
        await waitUntil { store.resolvedPlan == recovered }

        let criteria = await client.journeyRequests
        let tokens = await client.resolutionRequests
        XCTAssertEqual(criteria.count, 2)
        XCTAssertEqual(criteria[0], criteria[1])
        XCTAssertEqual(tokens, [["old-token"], ["fresh-token"]])
        XCTAssertEqual(store.selectedOutbound, fresh)
        XCTAssertFalse(store.selectionNeedsReview)
    }

    @MainActor
    func testExpiredRoundTripRerunsBothExactCriteriaBeforeOneRetry() async {
        let (oldOutbound, freshOutbound) = tokenRefreshOptions(fingerprint: "out-stable")
        let oldReturn = tokenizedReturn(token: "old-return")
        let freshReturn = tokenizedReturn(token: "fresh-return")
        let trips = JourneyPlanTestFixtures.makeTrips()
        let recovered = JourneySearchStoreFixtures.resolution(
            outbound: freshOutbound,
            outboundTrips: [trips[0]],
            returnOption: freshReturn,
            returnTrips: [trips[1]]
        )
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [oldOutbound])),
                .success(JourneySearchStoreFixtures.page(options: [oldReturn])),
                .success(JourneySearchStoreFixtures.page(options: [freshOutbound])),
                .success(JourneySearchStoreFixtures.page(options: [freshReturn])),
            ],
            resolutions: [.failure(.trackingTokenExpired), .success(recovered)]
        )
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(oldOutbound)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(oldReturn)
        store.resolveSelection()
        await waitUntil { store.resolvedPlan == recovered }

        let criteria = await client.journeyRequests
        let tokens = await client.resolutionRequests
        XCTAssertEqual(criteria.count, 4)
        XCTAssertEqual(criteria[0], criteria[2])
        XCTAssertEqual(criteria[1], criteria[3])
        XCTAssertEqual(tokens, [
            [oldOutbound.trackingToken, oldReturn.trackingToken],
            [freshOutbound.trackingToken, freshReturn.trackingToken],
        ])
        XCTAssertEqual(store.selectedReturn, freshReturn)
    }

    @MainActor
    func testExpiredMissingFingerprintReturnsToOutboundResultsForReview() async {
        let old = journeyOutboundOption(fingerprint: "missing")
        let other = journeyOutboundOption(id: "other", fingerprint: "other")
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [old])),
                .success(JourneySearchStoreFixtures.page(options: [other])),
            ],
            resolutions: [.failure(.trackingTokenExpired)]
        )
        let store = await prepareOneWayJourneyReview(client: client, outbound: old)
        store.resolveSelection()
        await waitUntil { store.selectionNeedsReview }

        XCTAssertEqual(store.phase, .showingOutbound)
        XCTAssertNil(store.selectedOutbound)
        XCTAssertEqual(store.outboundPage?.options, [other])
        let resolutionRequests = await client.resolutionRequests
        XCTAssertEqual(resolutionRequests.count, 1)
    }

    @MainActor
    func testExpiredSameFingerprintWithChangedTimeRequiresReview() async {
        let old = journeyOutboundOption(fingerprint: "stable")
        let changed = journeyOutboundOption(
            id: "changed",
            fingerprint: "stable",
            end: old.endTime.addingTimeInterval(60)
        )
        await assertExpiredMismatch(old: old, refreshed: changed)
    }

    @MainActor
    func testExpiredSameFingerprintWithChangedStationRequiresReview() async {
        let old = journeyOutboundOption(fingerprint: "stable")
        let station = JourneySearchStoreFixtures.place(
            id: "eu:transitous:nl-amsterdam-south",
            name: "Amsterdam Zuid",
            kind: .station,
            country: "NL",
            timeZone: "Europe/Amsterdam"
        )
        let changed = JourneySearchStoreFixtures.option(
            id: "changed-station",
            fingerprint: "stable",
            start: old.startTime,
            end: old.endTime,
            destination: station
        )
        await assertExpiredMismatch(old: old, refreshed: changed)
    }

    @MainActor
    func testExpiredChangedReturnPreservesReconciledOutboundAndRequiresReturnReview() async {
        let (oldOutbound, freshOutbound) = tokenRefreshOptions(fingerprint: "out-stable")
        let oldReturn = tokenizedReturn(token: "old-return")
        let changedReturn = JourneySearchStoreFixtures.option(
            id: "return",
            fingerprint: oldReturn.fingerprint,
            start: oldReturn.startTime.addingTimeInterval(60),
            end: oldReturn.endTime.addingTimeInterval(60),
            origin: JourneySearchStoreFixtures.amsterdam,
            destination: JourneySearchStoreFixtures.paris,
            token: "fresh-return"
        )
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [oldOutbound])),
                .success(JourneySearchStoreFixtures.page(options: [oldReturn])),
                .success(JourneySearchStoreFixtures.page(options: [freshOutbound])),
                .success(JourneySearchStoreFixtures.page(options: [changedReturn])),
            ],
            resolutions: [.failure(.trackingTokenExpired)]
        )
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(oldOutbound)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(oldReturn)

        store.resolveSelection()
        await waitUntil { store.selectionNeedsReview }

        XCTAssertEqual(store.phase, .showingReturn)
        XCTAssertEqual(store.selectedOutbound, freshOutbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertEqual(store.returnPage?.options, [changedReturn])
        let requests = await client.resolutionRequests
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testExpiredResolutionRetriesOnlyOnce() async {
        let (old, fresh) = tokenRefreshOptions(fingerprint: "stable")
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [old])),
                .success(JourneySearchStoreFixtures.page(options: [fresh])),
            ],
            resolutions: [.failure(.trackingTokenExpired), .failure(.trackingTokenExpired)]
        )
        let store = await prepareOneWayJourneyReview(client: client, outbound: old)
        store.resolveSelection()
        await waitUntil { store.phase == .failed(.trackingTokenExpired) }

        let requests = await client.resolutionRequests
        XCTAssertEqual(requests.count, 2)
    }

    @MainActor
    private func assertExpiredMismatch(old: JourneyOption, refreshed: JourneyOption) async {
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [old])),
                .success(JourneySearchStoreFixtures.page(options: [refreshed])),
            ],
            resolutions: [.failure(.trackingTokenExpired)]
        )
        let store = await prepareOneWayJourneyReview(client: client, outbound: old)
        store.resolveSelection()
        await waitUntil { store.selectionNeedsReview }

        XCTAssertEqual(store.phase, .showingOutbound)
        XCTAssertNil(store.selectedOutbound)
        XCTAssertNil(store.resolvedPlan)
    }

    private func tokenRefreshOptions(fingerprint: String) -> (JourneyOption, JourneyOption) {
        let old = JourneySearchStoreFixtures.option(
            id: "outbound",
            fingerprint: fingerprint,
            start: JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T09:50:00Z"),
            token: "old-token"
        )
        let fresh = JourneySearchStoreFixtures.option(
            id: "outbound",
            fingerprint: fingerprint,
            start: old.startTime,
            end: old.endTime,
            token: "fresh-token"
        )
        return (old, fresh)
    }

    private func tokenizedReturn(token: String) -> JourneyOption {
        JourneySearchStoreFixtures.option(
            id: "return",
            fingerprint: "return-stable",
            start: JourneySearchStoreFixtures.date("2026-07-25T06:25:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-25T09:45:00Z"),
            origin: JourneySearchStoreFixtures.amsterdam,
            destination: JourneySearchStoreFixtures.paris,
            token: token
        )
    }
}
