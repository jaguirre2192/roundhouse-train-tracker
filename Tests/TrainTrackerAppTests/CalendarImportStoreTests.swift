import EventKit
import Foundation
import XCTest
@testable import TrainTracker

@MainActor
final class CalendarImportStoreTests: XCTestCase {
    private enum TestFailure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Calendar service unavailable" }
    }

    func testInitializationDoesNotRequestAccessOrReadEvents() async {
        let client = CalendarImportTestClient(status: .notDetermined)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

        XCTAssertEqual(store.state, .idle)
        let requests = await client.accessRequestCount
        let windows = await client.fetchedWindows
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(windows.isEmpty)
    }

    func testGrantedAccessLoadsCandidatesUsingOnlyTheSuppliedWindow() async {
        let event = candidate("current")
        let window = DateInterval(start: Date(timeIntervalSince1970: 100), duration: 500)
        let client = CalendarImportTestClient(fetchResult: .success([event]))
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil), window: { window })

        await store.beginImport(includingEventKeys: [event.id])

        XCTAssertEqual(store.state, .loaded([event]))
        let requests = await client.accessRequestCount
        let windows = await client.fetchedWindows
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(windows, [window])
        let includedKeys = await client.includedEventKeys
        XCTAssertEqual(includedKeys, [[event.id]])
    }

    func testExplicitImportRequestsUndeterminedAccessAndThenLoads() async {
        let client = CalendarImportTestClient(status: .notDetermined)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

        await store.beginImport()

        XCTAssertEqual(store.state, .empty)
        let requests = await client.accessRequestCount
        let windows = await client.fetchedWindows
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(windows.count, 1)
    }

    func testDeclinedRequestDoesNotReadEvents() async {
        let client = CalendarImportTestClient(
            status: .notDetermined,
            accessResult: .success(false),
            authorizationAfterRequest: .denied
        )
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

        await store.beginImport()

        XCTAssertEqual(store.state, .denied)
        let windows = await client.fetchedWindows
        XCTAssertTrue(windows.isEmpty)
    }

    func testDeniedAndRestrictedAccessNeverPromptOrRead() async {
        for status in [EKAuthorizationStatus.denied, .restricted] {
            let client = CalendarImportTestClient(status: status)
            let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

            await store.beginImport()

            XCTAssertEqual(store.state, status == .restricted ? .restricted : .denied)
            let requests = await client.accessRequestCount
            let windows = await client.fetchedWindows
            XCTAssertEqual(requests, 0)
            XCTAssertTrue(windows.isEmpty)
        }
    }

    func testExplicitImportUpgradesWriteOnlyAccess() async {
        let client = CalendarImportTestClient(status: .writeOnly)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

        await store.beginImport()

        XCTAssertEqual(store.state, .empty)
        let requests = await client.accessRequestCount
        XCTAssertEqual(requests, 1)
    }

    func testDeniedWriteOnlyUpgradeDoesNotReadEvents() async {
        let client = CalendarImportTestClient(
            status: .writeOnly,
            accessResult: .success(false),
            authorizationAfterRequest: .writeOnly
        )
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

        await store.beginImport()

        XCTAssertEqual(store.state, .denied)
        let windows = await client.fetchedWindows
        XCTAssertTrue(windows.isEmpty)
    }

    func testPassiveRefreshNeverRequestsAccess() async {
        for status in [EKAuthorizationStatus.notDetermined, .writeOnly, .denied, .restricted] {
            let client = CalendarImportTestClient(status: status)
            let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

            await store.refresh()

            let expected: CalendarImportStore.State = status == .notDetermined ? .idle
                : status == .restricted ? .restricted : .denied
            XCTAssertEqual(store.state, expected)
            let requests = await client.accessRequestCount
            let windows = await client.fetchedWindows
            XCTAssertEqual(requests, 0)
            XCTAssertTrue(windows.isEmpty)
        }
    }

    func testRefreshReflectsSettingsGrantRevocationAndRegrant() async {
        let event = candidate("visible")
        let client = CalendarImportTestClient(status: .denied, fetchResult: .success([event]))
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        await store.beginImport()
        XCTAssertEqual(store.state, .denied)

        client.setAuthorization(.fullAccess)
        await store.refresh()
        XCTAssertEqual(store.state, .loaded([event]))

        client.setAuthorization(.restricted)
        await store.refresh()
        XCTAssertEqual(store.state, .restricted)

        client.setAuthorization(.writeOnly)
        await store.refresh()
        XCTAssertEqual(store.state, .denied)

        client.setAuthorization(.fullAccess)
        await store.refresh()
        XCTAssertEqual(store.state, .loaded([event]))
        let requests = await client.accessRequestCount
        let windows = await client.fetchedWindows
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(windows.count, 2)
    }

    func testDefaultWindowUsesFourteenPastAndOneHundredTwentyFutureCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 10)))

        let window = CalendarImportStore.defaultWindow(referenceDate: reference, calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.day], from: window.start, to: reference).day, 14)
        XCTAssertEqual(calendar.dateComponents([.day], from: reference, to: window.end).day, 120)
        XCTAssertEqual(calendar.component(.hour, from: window.start), 10)
        XCTAssertEqual(calendar.component(.hour, from: window.end), 10)
    }

    func testReadRechecksAuthorizationAfterARequestReturnsGranted() async {
        let client = CalendarImportTestClient(status: .notDetermined, authorizationAfterRequest: .restricted)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

        await store.beginImport()

        XCTAssertEqual(store.state, .restricted)
        let windows = await client.fetchedWindows
        XCTAssertTrue(windows.isEmpty)
    }

    func testRequestFailureSurfacesErrorWhenPermissionRemainsUndetermined() async {
        let client = CalendarImportTestClient(
            status: .notDetermined,
            accessResult: .failure(TestFailure.unavailable),
            authorizationAfterRequest: .notDetermined
        )
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))

        await store.beginImport()

        XCTAssertEqual(store.state, .error("Calendar service unavailable"))
    }

    func testFetchErrorsDistinguishAccessFailuresFromServiceFailure() async {
        let cases: [(Error, CalendarImportStore.State)] = [
            (CalendarImportClient.ClientError.accessDenied, .denied),
            (CalendarImportClient.ClientError.accessRestricted, .restricted),
            (TestFailure.unavailable, .error("Calendar service unavailable")),
            (CancellationError(), .idle),
        ]
        for (error, state) in cases {
            let client = CalendarImportTestClient(fetchResult: .failure(error))
            let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
            await store.beginImport()
            XCTAssertEqual(store.state, state)
        }
    }

    func testPassiveRefreshDoesNotInterruptAnExplicitPermissionSheet() async {
        let client = CalendarImportTestClient(status: .notDetermined, suspendsAccess: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let task = Task { await store.beginImport() }
        let requested = await client.waitForAccessRequest()
        XCTAssertTrue(requested)
        XCTAssertEqual(store.state, .requestingAccess)

        await store.refresh()
        XCTAssertEqual(store.state, .requestingAccess)
        await client.resumeAccess(status: .fullAccess, result: .success(true))
        await task.value

        XCTAssertEqual(store.state, .empty)
        let requests = await client.accessRequestCount
        XCTAssertEqual(requests, 1)
    }

    func testCancellingAccessRequestClearsProgressAndIgnoresItsLateGrant() async {
        let client = CalendarImportTestClient(status: .notDetermined, suspendsAccess: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let task = Task { await store.beginImport() }
        let requested = await client.waitForAccessRequest()
        XCTAssertTrue(requested)

        task.cancel()
        let clearedProgress = await waitForIdle(store)
        XCTAssertTrue(clearedProgress)
        await client.resumeAccess(status: .fullAccess, result: .success(true))
        await task.value

        XCTAssertEqual(store.state, .idle)
        let windows = await client.fetchedWindows
        XCTAssertTrue(windows.isEmpty)
    }

    func testCancellingFetchClearsProgressBeforeItsLateSuccess() async {
        let client = CalendarImportTestClient(suspendsFetch: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let task = Task { await store.beginImport() }
        let fetched = await client.waitForFetchCount(1)
        XCTAssertTrue(fetched)
        XCTAssertEqual(store.state, .loading)

        task.cancel()
        let clearedProgress = await waitForIdle(store)
        XCTAssertTrue(clearedProgress)
        await client.resumeFetch(result: .success([candidate("late")]))
        await task.value

        XCTAssertEqual(store.state, .idle)
    }

    func testResetDiscardsLateFetchSuccessAndFailure() async {
        let results: [Result<[CalendarJourneyCandidate], Error>] = [
            .success([candidate("stale")]), .failure(TestFailure.unavailable),
        ]
        for result in results {
            let client = CalendarImportTestClient(suspendsFetch: true)
            let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
            let task = Task { await store.beginImport() }
            let fetched = await client.waitForFetchCount(1)
            XCTAssertTrue(fetched)

            store.reset()
            await client.resumeFetch(result: result)
            await task.value

            XCTAssertEqual(store.state, .idle)
        }
    }

    func testNewerRefreshSupersedesOlderLoadAndItsError() async {
        let client = CalendarImportTestClient(suspendsFetch: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let first = Task { await store.beginImport() }
        let firstFetched = await client.waitForFetchCount(1)
        XCTAssertTrue(firstFetched)
        let second = Task { await store.refresh() }
        let secondFetched = await client.waitForFetchCount(2)
        XCTAssertTrue(secondFetched)
        let current = candidate("latest")

        await client.resumeFetch(1, result: .success([current]))
        await second.value
        await client.resumeFetch(0, result: .failure(CalendarImportClient.ClientError.accessDenied))
        await first.value

        XCTAssertEqual(store.state, .loaded([current]))
    }

    func testRevokedAccessCannotPublishAnAlreadyRunningFetch() async {
        for status in [EKAuthorizationStatus.denied, .restricted, .writeOnly] {
            let client = CalendarImportTestClient(suspendsFetch: true)
            let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
            let task = Task { await store.beginImport() }
            let fetched = await client.waitForFetchCount(1)
            XCTAssertTrue(fetched)

            client.setAuthorization(status)
            await client.resumeFetch(result: .success([candidate("private")]))
            await task.value

            XCTAssertEqual(store.state, status == .restricted ? .restricted : .denied)
        }
    }

    func testPreviouslyImportedEventRemainsVisibleAfterLosingTrainKeywords() throws {
        let original = candidate("renamed").snapshot
        let renamed = CalendarEventSnapshot(
            eventIdentifier: original.eventIdentifier,
            calendarTitle: original.calendarTitle,
            title: "Plans changed",
            notes: nil,
            location: nil,
            startDate: original.startDate,
            endDate: original.endDate,
            isAllDay: false
        )
        XCTAssertNil(CalendarImportClient.candidate(for: renamed, includingEventKeys: []))

        let included = try XCTUnwrap(CalendarImportClient.candidate(
            for: renamed,
            includingEventKeys: [original.importSource.eventKey]
        ))

        XCTAssertEqual(included.id, original.importSource.eventKey)
        XCTAssertEqual(included.classification.evidence, ["Previously imported calendar event"])
        XCTAssertNil(included.classification.originGuess)
        XCTAssertNil(included.classification.destinationGuess)
    }

    func testCancelledTrainCandidateKeepsItsStatusForReview() throws {
        let original = candidate("cancelled").snapshot
        let cancelled = CalendarEventSnapshot(
            eventIdentifier: original.eventIdentifier,
            calendarTitle: original.calendarTitle,
            title: original.title,
            notes: nil,
            location: nil,
            startDate: original.startDate,
            endDate: original.endDate,
            isAllDay: false,
            timeZoneIdentifier: "America/New_York",
            isCancelled: true,
            occurrenceDate: original.startDate
        )

        let included = try XCTUnwrap(CalendarImportClient.candidate(for: cancelled, includingEventKeys: []))

        XCTAssertTrue(included.snapshot.isCancelled)
        XCTAssertEqual(included.snapshot.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(included.snapshot.occurrenceDate, original.startDate)
    }

    private func waitForIdle(_ store: CalendarImportStore) async -> Bool {
        for _ in 0..<10_000 {
            if store.state == .idle { return true }
            await Task.yield()
        }
        return store.state == .idle
    }

    private func candidate(_ id: String) -> CalendarJourneyCandidate {
        CalendarJourneyCandidate(
            snapshot: CalendarEventSnapshot(
                eventIdentifier: id,
                calendarTitle: "Travel",
                title: "Amtrak Boston to New York",
                notes: nil,
                location: nil,
                startDate: Date(timeIntervalSince1970: 1_800_000_000),
                endDate: Date(timeIntervalSince1970: 1_800_010_000),
                isAllDay: false
            ),
            classification: CalendarJourneyClassification(
                confidence: .high,
                evidence: ["Mentions Amtrak"],
                originGuess: "Boston",
                destinationGuess: "New York",
                trainNumberGuess: nil
            )
        )
    }
}
