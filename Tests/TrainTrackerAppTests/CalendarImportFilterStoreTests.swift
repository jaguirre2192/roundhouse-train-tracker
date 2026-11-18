import EventKit
import Foundation
import XCTest
@testable import TrainTracker

@MainActor
final class CalendarImportFilterStoreTests: XCTestCase {
    func testLoadsSavedOptionsWithoutRequestingCalendarAccess() async throws {
        let context = try preferences()
        defer { context.cleanup() }
        let options = CalendarImportOptions(selectedCalendarIDs: ["work"], datePreset: .next30Days)
        try context.preferences.save(options)
        let client = CalendarImportTestClient(status: .notDetermined)

        let store = CalendarImportStore(client: client, preferences: context.preferences)

        XCTAssertEqual(store.options, options)
        XCTAssertTrue(store.calendars.isEmpty)
        let accessCount = await client.accessRequestCount
        let calendarCount = await client.calendarRequestCount
        XCTAssertEqual(accessCount, 0)
        XCTAssertEqual(calendarCount, 0)
    }

    func testAuthorizedLoadExposesCalendarDescriptorsAndUsesSavedSourceFilter() async throws {
        let context = try preferences()
        defer { context.cleanup() }
        try context.preferences.save(CalendarImportOptions(selectedCalendarIDs: ["work"]))
        let calendars = descriptors
        let client = CalendarImportTestClient(calendarResult: .success(calendars))
        let store = CalendarImportStore(client: client, preferences: context.preferences)

        await store.beginImport(includingEventKeys: ["known-event"])

        XCTAssertEqual(store.calendars, calendars)
        let selection = await client.selectedCalendarIDs
        let keys = await client.includedEventKeys
        XCTAssertEqual(selection, [["work"]])
        XCTAssertEqual(keys, [["known-event"]])
    }

    func testApplyingOptionsPersistsAndRefreshesWithBoundedDatesWithoutPrompting() async throws {
        let context = try preferences()
        defer { context.cleanup() }
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let client = CalendarImportTestClient(calendarResult: .success(descriptors))
        let store = CalendarImportStore(
            client: client, preferences: context.preferences,
            now: { reference }, calendar: { calendar }
        )
        let options = CalendarImportOptions(selectedCalendarIDs: ["personal"], datePreset: .next30Days)

        try await store.updateOptions(options, includingEventKeys: ["known-event"])

        XCTAssertEqual(store.options, options)
        XCTAssertEqual(context.preferences.load(), options)
        XCTAssertEqual(store.state, .empty)
        let windows = await client.fetchedWindows
        let selection = await client.selectedCalendarIDs
        let accessCount = await client.accessRequestCount
        XCTAssertEqual(windows, [try options.dateInterval(referenceDate: reference, calendar: calendar)])
        XCTAssertEqual(selection, [["personal"]])
        XCTAssertEqual(accessCount, 0)
    }

    func testEmptyCalendarSelectionIsForwardedAsEmptyAndStaysEmptyAfterReload() async throws {
        let context = try preferences()
        defer { context.cleanup() }
        let client = CalendarImportTestClient(calendarResult: .success(descriptors))
        let store = CalendarImportStore(client: client, preferences: context.preferences)

        try await store.updateOptions(CalendarImportOptions(selectedCalendarIDs: []))
        let reloaded = CalendarImportStore(client: client, preferences: context.preferences)
        await reloaded.beginImport()

        XCTAssertEqual(reloaded.options.selectedCalendarIDs, [])
        let selections = await client.selectedCalendarIDs
        XCTAssertEqual(selections, [Set<String>(), Set<String>()])
        XCTAssertEqual(reloaded.state, .empty)
    }

    func testOldProtocolFetchConvenienceStillMeansAllCalendars() async throws {
        let client = CalendarImportTestClient()
        let abstractClient: any CalendarImportClientProtocol = client
        let window = DateInterval(start: Date(timeIntervalSince1970: 100), duration: 500)

        _ = try await abstractClient.fetchCandidates(window: window, includingEventKeys: ["event"])

        let selections = await client.selectedCalendarIDs
        XCTAssertEqual(selections.count, 1)
        XCTAssertNil(selections[0])
    }

    func testInvalidOptionsDoNotPersistOrReplaceTheCurrentState() async throws {
        let context = try preferences()
        defer { context.cleanup() }
        let client = CalendarImportTestClient(calendarResult: .success(descriptors))
        let store = CalendarImportStore(client: client, preferences: context.preferences)
        await store.beginImport()
        let initial = store.options

        do {
            try await store.updateOptions(CalendarImportOptions(selectedCalendarIDs: [], datePreset: .custom))
            XCTFail("Missing dates should be rejected")
        } catch {
            XCTAssertEqual(error as? CalendarImportOptions.ValidationError, .missingCustomDates)
        }

        XCTAssertEqual(store.options, initial)
        XCTAssertEqual(context.preferences.load(), initial)
        XCTAssertEqual(store.state, .empty)
        let windows = await client.fetchedWindows
        XCTAssertEqual(windows.count, 1)
    }

    func testUpdatingOptionsAfterAccessRevocationClearsCalendarNamesAndDoesNotPrompt() async throws {
        let client = CalendarImportTestClient(calendarResult: .success(descriptors))
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        await store.beginImport()
        XCTAssertFalse(store.calendars.isEmpty)
        client.setAuthorization(.denied)

        try await store.updateOptions(CalendarImportOptions(datePreset: .next30Days))

        XCTAssertEqual(store.state, .denied)
        XCTAssertTrue(store.calendars.isEmpty)
        let accessCount = await client.accessRequestCount
        let calendarCount = await client.calendarRequestCount
        XCTAssertEqual(accessCount, 0)
        XCTAssertEqual(calendarCount, 1)
    }

    func testResetIgnoresCalendarMetadataArrivingAfterDismissal() async {
        let client = CalendarImportTestClient(suspendsCalendars: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let task = Task { await store.beginImport() }
        let started = await client.waitForCalendarCount(1)
        XCTAssertTrue(started)

        store.reset()
        await client.resumeCalendars(result: .success(descriptors))
        await task.value

        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.calendars.isEmpty)
        let windows = await client.fetchedWindows
        XCTAssertTrue(windows.isEmpty)
    }

    func testNewerRefreshCannotBeOverwrittenByOlderCalendarMetadata() async {
        let client = CalendarImportTestClient(suspendsCalendars: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let first = Task { await store.beginImport() }
        let firstStarted = await client.waitForCalendarCount(1)
        XCTAssertTrue(firstStarted)
        let second = Task { await store.refresh() }
        let secondStarted = await client.waitForCalendarCount(2)
        XCTAssertTrue(secondStarted)
        let current = [CalendarDescriptor(id: "current", title: "Trips", sourceTitle: "iCloud")]

        await client.resumeCalendars(1, result: .success(current))
        await second.value
        await client.resumeCalendars(0, result: .success(descriptors))
        await first.value

        XCTAssertEqual(store.calendars, current)
        XCTAssertEqual(store.state, .empty)
        let windows = await client.fetchedWindows
        XCTAssertEqual(windows.count, 1)
    }

    func testPermissionRevokedDuringMetadataLoadPreventsEventRead() async {
        let client = CalendarImportTestClient(suspendsCalendars: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let task = Task { await store.beginImport() }
        let started = await client.waitForCalendarCount(1)
        XCTAssertTrue(started)

        client.setAuthorization(.restricted)
        await client.resumeCalendars(result: .success(descriptors))
        await task.value

        XCTAssertEqual(store.state, .restricted)
        XCTAssertTrue(store.calendars.isEmpty)
        let windows = await client.fetchedWindows
        XCTAssertTrue(windows.isEmpty)
    }

    func testApplyingNewSourceFilterInvalidatesAnOlderEventLoad() async throws {
        let client = CalendarImportTestClient(calendarResult: .success(descriptors), suspendsFetch: true)
        let store = CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))
        let initial = Task { await store.beginImport() }
        let firstStarted = await client.waitForFetchCount(1)
        XCTAssertTrue(firstStarted, "The original event fetch must suspend before applying a new filter")
        guard firstStarted else {
            initial.cancel()
            store.reset()
            await client.cancelPendingRequests()
            return
        }
        let newOptions = CalendarImportOptions(selectedCalendarIDs: ["work"], datePreset: .next30Days)
        let updated = Task { try await store.updateOptions(newOptions) }
        let secondStarted = await client.waitForFetchCount(2)
        XCTAssertTrue(secondStarted, "The filtered event fetch must suspend before its result is released")
        guard secondStarted else {
            initial.cancel()
            updated.cancel()
            store.reset()
            await client.cancelPendingRequests()
            return
        }

        await client.resumeFetch(1, result: .success([]))
        try await updated.value
        await client.resumeFetch(0, result: .failure(CalendarImportClient.ClientError.accessDenied))
        await initial.value

        XCTAssertEqual(store.state, .empty)
        XCTAssertEqual(store.options, newOptions)
        let selections = await client.selectedCalendarIDs
        XCTAssertNil(selections[0])
        XCTAssertEqual(selections[1], ["work"])
    }

    private var descriptors: [CalendarDescriptor] {
        [
            CalendarDescriptor(id: "personal", title: "Travel", sourceTitle: "iCloud"),
            CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Google"),
        ]
    }

    private func preferences() throws -> (
        preferences: CalendarImportPreferences, cleanup: @MainActor () -> Void
    ) {
        let name = "CalendarImportFilterStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (CalendarImportPreferences(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }
}
