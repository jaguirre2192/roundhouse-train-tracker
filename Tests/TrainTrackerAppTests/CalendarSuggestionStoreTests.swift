import EventKit
import XCTest
@testable import TrainTracker

@MainActor
final class CalendarSuggestionStoreTests: XCTestCase {
    func testDisabledDoesNotPromptOrRead() async {
        let client = CalendarImportTestClient(status: .notDetermined)
        let store = makeStore(client)
        await store.refresh()
        let reads = await client.calendarRequestCount
        let prompts = await client.accessRequestCount
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(prompts, 0)
        XCTAssertFalse(store.isEnabled)
    }

    func testEnablingGrantedAccessReadsOnceWithoutPrompt() async {
        let client = CalendarImportTestClient()
        let store = makeStore(client)
        await store.enable()
        let reads = await client.fetchedWindows.count
        let prompts = await client.accessRequestCount
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(prompts, 0)
        XCTAssertTrue(store.isEnabled)
    }

    func testDeniedEnableNeverPromptsOrReads() async {
        let client = CalendarImportTestClient(status: .denied)
        let store = makeStore(client)
        await store.enable()
        await store.refresh()
        let reads = await client.calendarRequestCount
        let prompts = await client.accessRequestCount
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(store.state, .denied)
    }

    func testDismissalAndOptInSurviveRestartButRevisionCanReappear() async throws {
        let suite = "CalendarSuggestionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = candidate("one")
        let client = CalendarImportTestClient(fetchResult: .success([original]))
        let first = makeStore(client, defaults: defaults)
        await first.enable()
        first.dismiss(original)
        XCTAssertTrue(first.candidates(excludingSavedEventKeys: []).isEmpty)
        let revised = candidate("one", title: "Amtrak Boston to New York revised")
        let restarted = makeStore(CalendarImportTestClient(fetchResult: .success([original, revised])), defaults: defaults)
        XCTAssertTrue(restarted.isEnabled)
        await restarted.refresh()
        XCTAssertEqual(restarted.candidates(excludingSavedEventKeys: []), [revised])
        restarted.disable()
        XCTAssertFalse(makeStore(client, defaults: defaults).isEnabled)
    }

    func testSavedCancelledAndDuplicateEventsExcluded() async {
        let saved = candidate("saved")
        let cancelled = candidate("cancelled", cancelled: true)
        let available = candidate("new")
        let store = makeStore(CalendarImportTestClient(fetchResult: .success([saved, cancelled, available, available])))
        await store.enable()
        XCTAssertEqual(store.candidates(excludingSavedEventKeys: [saved.id]), [available])
        XCTAssertTrue(store.candidates(excludingSavedEventKeys: [saved.id, available.id]).isEmpty)
    }

    func testRefreshingRemovesAnUnimportedFalsePositiveButPreservesExplicitSavedEventReview() async throws {
        let event = CalendarEventSnapshot(
            eventIdentifier: "synthetic-old-false-positive", calendarTitle: "Test Calendar",
            title: "FT Future of AI Summit 2026 → Speakers' Dinner", notes: nil,
            location: "Example Hall, London EC2N 2HE",
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false
        )
        let oldCandidate = CalendarJourneyCandidate(
            snapshot: event,
            classification: CalendarJourneyClassification(
                confidence: .high, evidence: ["Recognized a train number", "Recognized a route pattern"],
                originGuess: "FT Future of AI Summit 2026", destinationGuess: "Speakers' Dinner", trainNumberGuess: "2N"
            )
        )
        let client = CalendarImportTestClient(suspendsFetch: true)
        let store = makeStore(client)
        let initialLoad = Task { await store.enable() }
        guard await client.waitForFetchCount(1) else {
            await client.cancelPendingRequests()
            await initialLoad.value
            XCTFail("Initial suggestion load did not start")
            return
        }
        await client.resumeFetch(result: .success([oldCandidate]))
        await initialLoad.value
        XCTAssertEqual(store.candidates(excludingSavedEventKeys: []), [oldCandidate])

        let freshCandidate = CalendarImportClient.candidate(for: event, includingEventKeys: [])
        XCTAssertNil(freshCandidate)
        let reload = Task { await store.refresh() }
        guard await client.waitForFetchCount(2) else {
            await client.cancelPendingRequests()
            await reload.value
            XCTFail("Suggestion refresh did not start")
            return
        }
        await client.resumeFetch(1, result: .success([freshCandidate].compactMap { $0 }))
        await reload.value
        XCTAssertEqual(store.state, .empty)
        XCTAssertTrue(store.candidates(excludingSavedEventKeys: []).isEmpty)

        // A prior deliberate import is still available for review under its exact identity.
        let retained = try XCTUnwrap(CalendarImportClient.candidate(
            for: event, includingEventKeys: [event.importSource.eventKey]
        ))
        XCTAssertEqual(retained.id, oldCandidate.id)
        XCTAssertEqual(retained.classification.evidence, ["Previously imported calendar event"])
        XCTAssertNil(retained.classification.trainNumberGuess)
        XCTAssertNil(retained.classification.originGuess)
        XCTAssertNil(retained.classification.destinationGuess)
    }

    func testDisableDiscardsLateFetchAndStopsFurtherReads() async {
        let client = CalendarImportTestClient(suspendsFetch: true)
        let store = makeStore(client)
        let pending = Task { await store.enable() }
        let started = await client.waitForFetchCount(1)
        XCTAssertTrue(started)
        store.disable()
        await client.resumeFetch(result: .success([candidate("late")]))
        await pending.value
        await store.refresh()
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.candidates(excludingSavedEventKeys: []).isEmpty)
        let reads = await client.fetchedWindows.count
        XCTAssertEqual(reads, 1)
    }

    func testDismissalDuringRefreshFiltersLateResult() async {
        let event = candidate("dismiss")
        let client = CalendarImportTestClient(suspendsFetch: true)
        let store = makeStore(client)
        let pending = Task { await store.enable() }
        let started = await client.waitForFetchCount(1)
        XCTAssertTrue(started)
        store.dismiss(event)
        await client.resumeFetch(result: .success([event]))
        await pending.value
        XCTAssertTrue(store.candidates(excludingSavedEventKeys: []).isEmpty)
    }

    func testDisableDuringPermissionRequestIgnoresLateGrant() async {
        let client = CalendarImportTestClient(status: .notDetermined, suspendsAccess: true)
        let store = makeStore(client)
        let pending = Task { await store.enable() }
        let started = await client.waitForAccessRequest()
        XCTAssertTrue(started)
        store.disable()
        await client.resumeAccess(status: .fullAccess, result: .success(true))
        await pending.value
        let reads = await client.calendarRequestCount
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(store.state, .idle)
    }

    func testOptionsAreSharedPersistedAndApplied() async throws {
        let suite = "CalendarSuggestionOptionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CalendarImportPreferences(defaults: defaults)
        let options = CalendarImportOptions(selectedCalendarIDs: ["travel"], datePreset: .next30Days)
        try preferences.save(options)
        let client = CalendarImportTestClient()
        let store = CalendarSuggestionStore(client: client, preferences: preferences, defaults: nil)
        XCTAssertEqual(store.importStore.options, options)
        await store.enable()
        let selections = await client.selectedCalendarIDs
        XCTAssertEqual(selections, [["travel"]])
    }

    func testReturningToMyTripsReusesRecentResultsAndNotNowNeverReads() async throws {
        let suite = "CalendarSuggestionIntroTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = CalendarImportTestClient(status: .notDetermined)
        let dismissed = makeStore(client, defaults: defaults)
        dismissed.dismissIntroduction()
        await dismissed.refreshIfStale()
        XCTAssertTrue(makeStore(client, defaults: defaults).isIntroductionDismissed)
        let prompts = await client.accessRequestCount
        let reads = await client.calendarRequestCount
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(reads, 0)

        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let granted = CalendarImportTestClient(fetchResult: .success([candidate("one")]))
        let store = CalendarSuggestionStore(
            client: granted, preferences: CalendarImportPreferences(defaults: nil), defaults: nil, now: { clock }
        )
        await store.enable()
        await store.refreshIfStale()
        var fetches = await granted.fetchedWindows.count
        XCTAssertEqual(fetches, 1)
        clock = clock.addingTimeInterval(301)
        await store.refreshIfStale()
        fetches = await granted.fetchedWindows.count
        XCTAssertEqual(fetches, 2)
    }

    private func makeStore(_ client: CalendarImportTestClient, defaults: UserDefaults? = nil) -> CalendarSuggestionStore {
        CalendarSuggestionStore(client: client, preferences: CalendarImportPreferences(defaults: nil), defaults: defaults)
    }

    private func candidate(_ id: String, title: String = "Amtrak Boston to New York", cancelled: Bool = false) -> CalendarJourneyCandidate {
        CalendarJourneyCandidate(
            snapshot: CalendarEventSnapshot(
                eventIdentifier: id, calendarTitle: "Travel", title: title, notes: nil, location: nil,
                startDate: Date(timeIntervalSince1970: 1_800_000_000),
                endDate: Date(timeIntervalSince1970: 1_800_010_000), isAllDay: false, isCancelled: cancelled
            ),
            classification: CalendarJourneyClassification(confidence: .high, evidence: ["Amtrak"], originGuess: "Boston", destinationGuess: "New York", trainNumberGuess: nil)
        )
    }
}
