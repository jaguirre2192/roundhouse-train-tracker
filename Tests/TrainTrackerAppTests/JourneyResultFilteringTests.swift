import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyResultFilteringTests: XCTestCase {
    func testMaximumChangesMenuModelUsesTheSupportedRange() {
        XCTAssertEqual(JourneyMaximumChangesMenuModel.supportedValues, [1, 2, 3, 4])
    }

    func testScreenshotPreviewModeRequiresAnExplicitLaunchArgument() {
        XCTAssertNil(JourneyResultsPreviewMode.resolve(arguments: ["TrainTracker"]))
        XCTAssertEqual(
            JourneyResultsPreviewMode.resolve(arguments: ["TrainTracker", "-JourneyResultsPreviewOutbound"]),
            .outbound
        )
        XCTAssertEqual(
            JourneyResultsPreviewMode.resolve(arguments: ["TrainTracker", "-JourneyResultsPreviewReturn"]),
            .return
        )
        XCTAssertEqual(
            JourneyResultsPreviewMode.resolve(arguments: ["-JourneyResultsPreviewJapanese"]),
            .japanese
        )
    }

    func testJapaneseScreenshotFixtureContainsLongJapaneseRailCopy() throws {
        let fixture = JourneyJapanesePreviewFixture()
        let option = try XCTUnwrap(fixture.outboundPage.options.first)
        let rail = try XCTUnwrap(firstRail(in: option))
        let stationName = rail.to.place.displayName

        XCTAssertTrue(stationName.unicodeScalars.contains { $0.value > 127 })
        XCTAssertGreaterThanOrEqual(stationName.count, 15)
        XCTAssertTrue(rail.operatorName.unicodeScalars.contains { $0.value > 127 })
        XCTAssertGreaterThanOrEqual(rail.operatorName.count, 18)
    }

    func testPreviewHorizontalSizeClassRequiresAnExplicitLaunchArgument() {
        XCTAssertNil(JourneyPreviewHorizontalSizeClass.resolve(arguments: ["TrainTracker"]))
        XCTAssertEqual(
            JourneyPreviewHorizontalSizeClass.resolve(arguments: ["-JourneyPreviewCompactWidth"]),
            .compact
        )
        XCTAssertNil(JourneyPreviewViewport.resolve(arguments: ["TrainTracker"]))
        XCTAssertEqual(
            JourneyPreviewViewport.resolve(arguments: ["-JourneyPreviewCompactWidth"])?.contentMaxWidth,
            480
        )
    }

    func testLiveRoundTripQAModeIsExplicitAndBuildsAProductionRoute() throws {
        XCTAssertNil(JourneyLiveRoundTripQAMode.resolve(arguments: ["TrainTracker"]))
        XCTAssertNotNil(
            JourneyLiveRoundTripQAMode.resolve(
                arguments: ["TrainTracker", "-JourneyLiveRoundTripQA"]
            )
        )

        let now = JourneySearchStoreFixtures.date("2026-07-22T12:00:00Z")
        let mode = try XCTUnwrap(
            JourneyLiveRoundTripQAMode.resolve(arguments: ["-JourneyLiveRoundTripQA"])
        )
        let form = mode.form(relativeTo: now)

        XCTAssertEqual(form.origin?.displayName, "Paris-Nord")
        XCTAssertEqual(form.destination?.displayName, "Amsterdam Centraal")
        XCTAssertTrue(form.returnEnabled)
        XCTAssertGreaterThan(form.outboundTime, now)
        XCTAssertGreaterThan(form.returnTime, form.outboundTime)
    }

    func testReviewPreviewModesAreExplicitAndDeterministic() {
        XCTAssertNil(JourneyReviewPreviewMode.resolve(arguments: ["TrainTracker"]))
        XCTAssertEqual(
            JourneyReviewPreviewMode.resolve(arguments: ["-JourneyReviewPreviewAll"]),
            .all
        )
        XCTAssertEqual(
            JourneyReviewPreviewMode.resolve(arguments: ["-JourneyReviewPreviewPartial"]),
            .partial
        )
        XCTAssertEqual(
            JourneyReviewPreviewMode.resolve(arguments: ["-JourneyReviewPreviewNone"]),
            JourneyReviewPreviewMode?.some(.none)
        )
    }

    @MainActor
    func testReviewPreviewFixturesCoverAllThreeResolutionStates() {
        let fixture = JourneyResultsPreviewFixture()

        let summaries = JourneyReviewPreviewMode.allCases.map { mode in
            JourneyResolutionSummary(
                resolution: mode.resolution(fixture: fixture),
                isRoundTrip: true,
                availableSubsetConfirmed: false
            )
        }

        // Three resolution states, then five coverage fixtures in which every train resolves.
        XCTAssertEqual(summaries.map(\.state), [.all, .partial, .none, .all, .all, .all, .all, .all])
        XCTAssertEqual(summaries.map(\.failures.count), [0, 1, 2, 0, 0, 0, 0, 0])
        XCTAssertEqual(summaries.map(\.coverage.notice?.title), [
            nil, nil, nil,
            "Live coverage varies by train", "Schedule only", "Live coverage not confirmed",
            "Live coverage varies by train", "Updates unavailable right now",
        ])
        XCTAssertEqual(summaries[4].primaryActionTitle, "Save Round Trip")
    }

    func testScreenshotPreviewPagesAreDeterministicAndDirectionallyReversed() throws {
        let fixture = JourneyResultsPreviewFixture()
        let direct = try XCTUnwrap(
            fixture.outboundPage.options.first { $0.id == "preview-direct" }
        )
        let overnight = try XCTUnwrap(
            fixture.outboundPage.options.first { $0.id == "preview-overnight" }
        )

        XCTAssertEqual(fixture.outboundPage.options.count, 2)
        XCTAssertEqual(fixture.outboundPage.previousCursor, "preview.previous.signed")
        XCTAssertEqual(fixture.outboundPage.nextCursor, "preview.next.signed")
        XCTAssertEqual(firstRail(in: direct)?.from.place, fixture.form.origin)
        XCTAssertEqual(firstRail(in: fixture.returnPage.options[0])?.from.place, fixture.form.destination)
        XCTAssertTrue(overnight.segments.contains { segment in
            guard case let .walk(walk) = segment else { return false }
            return walk.isStationChange
        })
    }

    func testOptionsAreChronologicalWithStableIdentityTieBreak() {
        let sameTime = JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z")
        let later = JourneySearchStoreFixtures.option(
            id: "later",
            fingerprint: "later",
            start: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T11:00:00Z")
        )
        let second = JourneySearchStoreFixtures.option(
            id: "b",
            fingerprint: "b",
            start: sameTime,
            end: sameTime.addingTimeInterval(3_600)
        )
        let first = JourneySearchStoreFixtures.option(
            id: "a",
            fingerprint: "a",
            start: sameTime,
            end: sameTime.addingTimeInterval(3_000)
        )

        let visible = JourneyResultFiltering.options(
            in: [later, second, first],
            directOnly: false
        )

        XCTAssertEqual(visible.map(\.id), ["a", "b", "later"])
    }

    func testOptionsAreOrderedByDisplayedExpectedDeparture() {
        let scheduledFirstButDelayed = JourneySearchStoreFixtures.option(
            id: "delayed",
            fingerprint: "delayed",
            start: JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z"),
            expectedDeparture: JourneySearchStoreFixtures.date("2026-07-24T09:30:00Z")
        )
        let scheduledLaterButExpectedEarlier = JourneySearchStoreFixtures.option(
            id: "expected-earlier",
            fingerprint: "expected-earlier",
            start: JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T11:00:00Z"),
            expectedDeparture: JourneySearchStoreFixtures.date("2026-07-24T09:10:00Z")
        )

        let visible = JourneyResultFiltering.options(
            in: [scheduledFirstButDelayed, scheduledLaterButExpectedEarlier],
            directOnly: false
        )

        XCTAssertEqual(visible.map(\.id), ["expected-earlier", "delayed"])
    }

    func testDirectOnlyIsDisplayFilteringAndDoesNotDiscardConnectingPageData() {
        let direct = journeyOption(id: "direct", changes: 0)
        let connection = journeyOption(id: "connection", changes: 1)
        let page = JourneySearchStoreFixtures.page(options: [connection, direct])

        let visible = JourneyResultFiltering.options(in: page.options, directOnly: true)

        XCTAssertEqual(visible.map(\.id), ["direct"])
        XCTAssertEqual(page.options.map(\.id), ["connection", "direct"])
    }

    func testEmptyReturnPageWithSignedCursorKeepsResultsDisposition() {
        let page = JourneySearchStoreFixtures.page(
            options: [],
            next: "signed.next.return.window"
        )

        XCTAssertEqual(
            JourneySearchPolicy.returnPageDisposition(page),
            .results
        )
    }

    func testEmptyReturnPageWithoutSignedCursorUsesTerminalRecoveryDisposition() {
        let page = JourneySearchStoreFixtures.page(options: [])

        XCTAssertEqual(
            JourneySearchPolicy.returnPageDisposition(page),
            .terminalRecovery
        )
    }

    @MainActor
    func testDirectOnlyClearsOnlyTheSelectionHiddenInThatDirection() async {
        let outbound = journeyOption(id: "outbound", changes: 0)
        let returnOption = journeyOption(
            id: "return",
            changes: 1,
            origin: JourneySearchStoreFixtures.amsterdam,
            destination: JourneySearchStoreFixtures.paris,
            start: JourneySearchStoreFixtures.date("2026-07-25T08:00:00Z")
        )
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [returnOption])),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(returnOption)

        store.setDirectOnly(true)

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertEqual(store.phase, .showingReturn)
    }

    @MainActor
    func testMaximumChangesRerunsOutboundAndClearsBothDirections() async {
        let outbound = journeyOption(id: "outbound", changes: 2)
        let replacement = journeyOption(id: "replacement", changes: 1)
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [replacement])),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }

        store.rerunWithMaximumTransfers(1, direction: .outbound)
        await waitUntil { store.outboundPage?.options == [replacement] }

        let requests = await client.journeyRequests
        XCTAssertEqual(requests.map(\.maximumTransfers), [4, 1])
        XCTAssertNil(store.selectedOutbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertNil(store.returnPage)
        XCTAssertEqual(store.phase, .showingOutbound)
    }

    @MainActor
    func testMaximumChangesRerunsReturnAndPreservesOutbound() async {
        let outbound = journeyOption(id: "outbound", changes: 0)
        let oldReturn = journeyOption(
            id: "old-return",
            changes: 2,
            origin: JourneySearchStoreFixtures.amsterdam,
            destination: JourneySearchStoreFixtures.paris,
            start: JourneySearchStoreFixtures.date("2026-07-25T08:00:00Z")
        )
        let replacement = journeyOption(
            id: "new-return",
            changes: 1,
            origin: JourneySearchStoreFixtures.amsterdam,
            destination: JourneySearchStoreFixtures.paris,
            start: JourneySearchStoreFixtures.date("2026-07-25T09:00:00Z")
        )
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [oldReturn])),
            .success(JourneySearchStoreFixtures.page(options: [replacement])),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(oldReturn)

        store.rerunWithMaximumTransfers(1, direction: .return)
        await waitUntil { store.returnPage?.options == [replacement] }

        let requests = await client.journeyRequests
        XCTAssertEqual(requests.map(\.maximumTransfers), [4, 4, 1])
        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertEqual(store.phase, .showingReturn)
    }

    @MainActor
    func testSignedPaginationCursorsReplaceRatherThanAppendPages() async {
        let first = journeyOption(id: "first", changes: 0)
        let replacement = journeyOption(id: "replacement", changes: 0)
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [first], next: "signed.next.cursor")),
            .success(JourneySearchStoreFixtures.page(options: [replacement], previous: "signed.previous.cursor")),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.outboundPage?.nextCursor != nil }

        store.loadLaterOutbound()
        await waitUntil { store.outboundPage?.previousCursor != nil }

        let requests = await client.journeyRequests
        XCTAssertEqual(requests.map(\.cursor), [nil, "signed.next.cursor"])
        XCTAssertEqual(store.outboundPage?.options.map(\.id), ["replacement"])
    }

    private func journeyOption(
        id: String,
        changes: Int,
        origin: RailPlace = JourneySearchStoreFixtures.paris,
        destination: RailPlace = JourneySearchStoreFixtures.amsterdam,
        start: Date = JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z")
    ) -> JourneyOption {
        JourneySearchStoreFixtures.option(
            id: id,
            fingerprint: id,
            start: start,
            end: start.addingTimeInterval(7_200),
            origin: origin,
            destination: destination,
            transferCount: changes
        )
    }

    private func firstRail(in option: JourneyOption) -> RailJourneySegment? {
        option.segments.lazy.compactMap { segment in
            guard case let .rail(rail) = segment else { return nil }
            return rail
        }.first
    }
}
