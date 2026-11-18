import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class JourneySearchRecoverySignatureTests: XCTestCase {
    @MainActor
    func testExpiredSameFingerprintWithChangedIntermediateExpectedArrivalRequiresReview() async {
        let old = option(expectedArrival: date("2026-07-24T08:00:00Z"), token: "old")
        let changed = option(expectedArrival: date("2026-07-24T08:10:00Z"), token: "fresh")

        await assertExpiredRefreshNeedsReview(old: old, refreshed: changed)
    }

    @MainActor
    func testExpiredSameFingerprintWithChangedIntermediateExpectedDepartureRequiresReview() async {
        let old = option(expectedDeparture: date("2026-07-24T08:05:00Z"), token: "old")
        let changed = option(expectedDeparture: date("2026-07-24T08:15:00Z"), token: "fresh")

        await assertExpiredRefreshNeedsReview(old: old, refreshed: changed)
    }

    @MainActor
    func testExpiredSameFingerprintWithCancelledIntermediateCallRequiresReview() async {
        let old = option(token: "old")
        let changed = option(intermediateCancelled: true, token: "fresh")

        await assertExpiredRefreshNeedsReview(old: old, refreshed: changed)
    }

    @MainActor
    func testExpiredSameFingerprintWithCancelledRailSegmentRequiresReview() async {
        let old = option(token: "old")
        let changed = option(segmentCancelled: true, token: "fresh")

        await assertExpiredRefreshNeedsReview(old: old, refreshed: changed)
    }

    @MainActor
    private func assertExpiredRefreshNeedsReview(
        old: JourneyOption,
        refreshed: JourneyOption,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let client = ScriptedJourneySearchClient(
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [old])),
                .success(JourneySearchStoreFixtures.page(options: [refreshed])),
            ],
            resolutions: [
                .failure(.trackingTokenExpired),
                .success(JourneyPlanResolution(directions: [])),
            ]
        )
        let store = await prepareOneWayJourneyReview(client: client, outbound: old)

        store.resolveSelection()
        await waitUntil { !store.isJourneyTaskActive }

        XCTAssertTrue(store.selectionNeedsReview, file: file, line: line)
        XCTAssertEqual(store.phase, .showingOutbound, file: file, line: line)
        XCTAssertNil(store.selectedOutbound, file: file, line: line)
        XCTAssertNil(store.resolvedPlan, file: file, line: line)
    }

    private func option(
        expectedArrival: Date? = nil,
        expectedDeparture: Date? = nil,
        intermediateCancelled: Bool = false,
        segmentCancelled: Bool = false,
        token: String
    ) -> JourneyOption {
        let start = date("2026-07-24T06:25:00Z")
        let end = date("2026-07-24T09:50:00Z")
        let origin = JourneySearchStoreFixtures.paris
        let destination = JourneySearchStoreFixtures.amsterdam
        let intermediate = JourneySearchStoreFixtures.place(
            id: "eu:transitous:be-brussels",
            name: "Brussels",
            country: "BE",
            timeZone: "Europe/Brussels"
        )
        let from = call(
            place: origin,
            scheduledArrival: nil,
            scheduledDeparture: start
        )
        let via = call(
            place: intermediate,
            scheduledArrival: date("2026-07-24T08:00:00Z"),
            scheduledDeparture: date("2026-07-24T08:05:00Z"),
            expectedArrival: expectedArrival,
            expectedDeparture: expectedDeparture,
            isCancelled: intermediateCancelled
        )
        let to = call(
            place: destination,
            scheduledArrival: end,
            scheduledDeparture: nil
        )
        let rail = RailJourneySegment(
            id: "outbound-rail",
            tripID: RailIdentifier(rawValue: "eu:transitous:outbound-trip"),
            serviceDate: start,
            operatorName: "Example Rail",
            product: "High speed",
            trainNumber: "9315",
            trainName: nil,
            from: from,
            to: to,
            intermediateCalls: [via],
            isCancelled: segmentCancelled,
            isRealtime: true,
            isTrackable: true,
            untrackableReason: nil
        )
        return JourneyOption(
            id: "outbound",
            fingerprint: "stable-fingerprint",
            startTime: start,
            endTime: end,
            duration: end.timeIntervalSince(start),
            transferCount: 0,
            segments: [.rail(rail)],
            badges: [.direct],
            trackability: JourneyTrackability(trackableRailSegments: 1, totalRailSegments: 1),
            realtimeFreshness: nil,
            attributions: ["Transitous"],
            trackingToken: token
        )
    }

    private func call(
        place: RailPlace,
        scheduledArrival: Date?,
        scheduledDeparture: Date?,
        expectedArrival: Date? = nil,
        expectedDeparture: Date? = nil,
        isCancelled: Bool = false
    ) -> JourneyCall {
        JourneyCall(
            place: place,
            city: place.kind == .city ? place : nil,
            scheduledArrival: scheduledArrival,
            scheduledDeparture: scheduledDeparture,
            expectedArrival: expectedArrival,
            expectedDeparture: expectedDeparture,
            plannedPlatform: nil,
            expectedPlatform: nil,
            isCancelled: isCancelled
        )
    }

    private func date(_ value: String) -> Date {
        JourneySearchStoreFixtures.date(value)
    }
}
