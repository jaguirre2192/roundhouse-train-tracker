import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

/// Regression coverage for the 2026-09-30 Calendar reliability fixes: stable identity for
/// rescheduled one-off events, time-zone-safe revisions, legacy compatibility, duplicate
/// suppression, changed saved events, shared options and false-positive keywords.
@MainActor
final class CalendarSuggestionReliabilityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Identity

    func testOneOffEventKeyIgnoresItsOccurrenceDateSoRescheduleKeepsIdentity() {
        let before = snapshot(start: start, occurrence: start)
        let moved = snapshot(start: start.addingTimeInterval(90_000), occurrence: start.addingTimeInterval(90_000))
        XCTAssertEqual(before.importSource.eventKey, moved.importSource.eventKey)
        XCTAssertNotEqual(before.importSource.revision, moved.importSource.revision)
        XCTAssertNotEqual(before.importSource.eventKey, before.legacyImportSource.eventKey,
                          "Legacy keys for one-off events included the start date")
    }

    func testRecurringOccurrencesStayDistinct() {
        let first = snapshot(start: start, occurrence: start, recurring: true)
        let second = snapshot(start: start.addingTimeInterval(86_400), occurrence: start.addingTimeInterval(86_400), recurring: true)
        XCTAssertNotEqual(first.importSource.eventKey, second.importSource.eventKey)
        XCTAssertEqual(first.importSource.eventKey, first.legacyImportSource.eventKey,
                       "Recurring keys keep the pre-fix format")
    }

    func testFloatingRecurringOccurrenceKeepsItsIdentityAfterTravelAndMigratesTheOlderKey() async throws {
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        func instance(day: Int, allDay: Bool = false) throws -> CalendarJourneyCandidate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = NSTimeZone.default
            let local = try XCTUnwrap(calendar.date(from: DateComponents(year: 2032, month: 5, day: day, hour: allDay ? 0 : 9)))
            let event = CalendarEventSnapshot(
                eventIdentifier: allDay ? "days" : "commute", calendarTitle: "Travel", title: "Amtrak 171",
                notes: nil, location: nil, startDate: local, endDate: local.addingTimeInterval(3_600),
                isAllDay: allDay, occurrenceDate: local, isRecurring: true)
            return CalendarJourneyCandidate(snapshot: event, classification: classification())
        }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let before = try instance(day: 4)
        let allDayBefore = try instance(day: 4, allDay: true)
        // Prior to this fix, recurring keys used the absolute occurrence date alongside the
        // contemporary revision, which was already based on local clock values.
        let older = CalendarJourneySource(eventKey: before.snapshot.legacyImportSource.eventKey, revision: before.snapshot.importSource.revision)
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let draft = JourneyPlanTestFixtures.makeDraft(id: UUID())
        let saved = try library.track(draft: JourneyPlanDraft(id: draft.id, origin: draft.origin, destination: draft.destination,
            outbound: draft.outbound, returnOption: nil, calendarSource: older),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]]))

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let after = try instance(day: 4)
        let nextWeek = try instance(day: 11)
        XCTAssertEqual(before.snapshot.importSource, after.snapshot.importSource)
        XCTAssertEqual(allDayBefore.snapshot.importSource, try instance(day: 4, allDay: true).snapshot.importSource)
        XCTAssertNotEqual(after.id, nextWeek.id)
        XCTAssertNotEqual(older.eventKey, after.snapshot.legacyImportSource.eventKey)
        XCTAssertNil(nextWeek.snapshot.priorFloatingKey(among: [older.eventKey]))
        library.adoptStableCalendarKeys(for: [nextWeek, after])
        let reloaded = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        XCTAssertEqual(reloaded.plans.count, 1)
        XCTAssertEqual(reloaded.plan(importedFrom: after.id)?.id, saved.id)
        XCTAssertEqual(reloaded.plan(importedFrom: after.id)?.calendarSource?.revision, after.snapshot.importSource.revision)

        let suite = "CalendarSuggestionReliabilityTests.travel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([older.eventKey + ":" + older.revision], forKey: "calendarSuggestions.v1.dismissed")
        let store = CalendarSuggestionStore(client: CalendarImportTestClient(fetchResult: .success([after, nextWeek])),
                                            preferences: CalendarImportPreferences(defaults: nil), defaults: defaults)
        await store.enable()
        XCTAssertEqual(store.candidates(savedPlans: []).map(\.id), [nextWeek.id])

        // These local dates are 24 hours apart in two zones but have the same old
        // absolute key. A scan containing only the following day must keep it distinct.
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let followingDay = try instance(day: 5)
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let priorDay = try instance(day: 4)
        XCTAssertEqual(priorDay.snapshot.legacyImportSource.eventKey, followingDay.snapshot.legacyImportSource.eventKey)
        XCTAssertFalse(followingDay.snapshot.acceptsLegacyRevision(priorDay.snapshot.importSource.revision))
    }

    // MARK: Revision

    func testAllDayRevisionSurvivesATimeZoneChange() throws {
        let previous = NSTimeZone.default
        defer { NSTimeZone.default = previous }
        // Each read happens in the zone the device is in at that moment, as EventKit does.
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let inLosAngeles = allDaySnapshot(year: 2032, month: 5, day: 4)
        let losAngelesRevision = inLosAngeles.importSource.revision
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let inParis = allDaySnapshot(year: 2032, month: 5, day: 4)
        let parisRevision = inParis.importSource.revision
        XCTAssertNotEqual(inLosAngeles.startDate, inParis.startDate, "EventKit moves all-day events with the device zone")
        XCTAssertEqual(losAngelesRevision, parisRevision)
        XCTAssertNotEqual(inLosAngeles.legacyImportSource.revision, inParis.legacyImportSource.revision,
                          "The pre-fix revision changed with the zone")
    }

    func testZonedEventRevisionIsUnchangedFromTheLegacyFormat() {
        let zoned = snapshot(start: start, occurrence: start, zone: "America/New_York")
        XCTAssertEqual(zoned.importSource.revision, zoned.legacyImportSource.revision)
        XCTAssertTrue(zoned.matchesRevision(zoned.legacyImportSource.revision))
    }

    func testJourneysSavedWithALegacyRevisionStillReadAsAlreadyAdded() {
        let floating = snapshot(start: start, occurrence: start, zone: nil)
        let saved = savedPlan(
            source: CalendarJourneySource(eventKey: floating.importSource.eventKey, revision: floating.legacyImportSource.revision)
        )
        let candidate = CalendarJourneyCandidate(snapshot: floating, classification: classification())
        XCTAssertEqual(CalendarImportDisposition(candidate: candidate, savedPlan: saved), .alreadyAdded)
    }

    // MARK: Suggestions

    func testSameTripInTwoCalendarsIsSuggestedOnce() async {
        let work = candidate(id: "work-copy", calendar: "Work")
        let personal = candidate(id: "personal-copy", calendar: "Personal")
        let store = await enabledStore(with: [work, personal])
        XCTAssertEqual(store.candidates(savedPlans: []).map(\.id), [work.id])
    }

    func testSuggestionsRecogniseExactSavedServiceButKeepOtherDeparturesAndStations() async throws {
        let event = snapshot(start: start, occurrence: start, id: "service", title: "Amtrak 171", location: "Boston South Station to New York Penn Station")
        let suggestion = try XCTUnwrap(CalendarImportClient.candidate(for: event, includingEventKeys: []))
        let store = await enabledStore(with: [suggestion])
        func plan(_ service: String, delayMinutes: Int = 0, origin: String = "Boston South Station") -> TrackedJourneyPlan {
            savedPlan(origin: origin, destination: "New York Penn Station", departure: start.addingTimeInterval(Double(delayMinutes) * 60),
                      service: service)
        }
        XCTAssertTrue(store.candidates(savedPlans: [plan("Amtrak 171")]).isEmpty)
        for other in [plan("Amtrak 173"), plan("Amtrak 171", delayMinutes: 20), plan("Amtrak 171", origin: "Boston North Station")] {
            XCTAssertEqual(store.candidates(savedPlans: [other]).map(\.id), [suggestion.id])
        }
        // Old plans without a known service cannot positively identify a different calendar entry.
        XCTAssertEqual(store.candidates(savedPlans: [savedPlan()]).map(\.id), [suggestion.id])
    }

    func testFloatingCalendarSuggestionUsesTheBoardingClockBeforeSuppressingASavedService() throws {
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        var clock = Calendar(identifier: .gregorian)
        clock.timeZone = NSTimeZone.default
        let local = DateComponents(year: 2032, month: 5, day: 4, hour: 9)
        let phoneTime = try XCTUnwrap(clock.date(from: local))
        let snapshot = snapshot(start: phoneTime, occurrence: phoneTime, zone: nil, title: "Amtrak 171",
                                location: "Boston South Station to New York Penn Station")
        let candidate = try XCTUnwrap(CalendarImportClient.candidate(for: snapshot, includingEventKeys: []))
        clock.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let boardingTime = try XCTUnwrap(clock.date(from: local))
        func plan(_ time: Date) -> TrackedJourneyPlan {
            savedPlan(origin: "Boston South Station", destination: "New York Penn Station", departure: time, service: "Amtrak 171")
        }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        XCTAssertFalse(CalendarSuggestionMatching.duplicatesSavedPlan(candidate, in: [plan(phoneTime)]))
        XCTAssertTrue(CalendarSuggestionMatching.duplicatesSavedPlan(candidate, in: [plan(boardingTime)]))
    }

    func testDismissingCopiedDepartureAcrossCalendarsSurvivesRestartAndAllowsAnEdit() async throws {
        let suite = "CalendarSuggestionReliabilityTests.copies.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func copy(_ id: String, title: String, startDate: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> CalendarEventSnapshot {
            snapshot(start: startDate, occurrence: startDate, id: id, calendar: id, title: title, location: "Boston to New York")
        }
        let first = copy("Personal", title: "Amtrak 171")
        let second = copy("Work", title: "Train 171")
        func suggestions(_ snapshots: [CalendarEventSnapshot]) -> CalendarSuggestionStore {
            CalendarSuggestionStore(client: CalendarImportTestClient(snapshots: snapshots),
                                    preferences: CalendarImportPreferences(defaults: nil), defaults: defaults)
        }
        let store = suggestions([first, second])
        await store.enable()
        let visible = store.candidates(savedPlans: [])
        XCTAssertEqual(visible.count, 1)
        store.dismiss(try XCTUnwrap(visible.first))
        XCTAssertTrue(store.candidates(savedPlans: []).isEmpty)

        let moved = copy("Work", title: "Train 171", startDate: start.addingTimeInterval(7_200))
        let reopened = suggestions([first, moved, copy("Another", title: "Amtrak 171")])
        await reopened.refresh()
        XCTAssertEqual(reopened.candidates(savedPlans: []).map(\.id), [moved.importSource.eventKey])
    }

    func testHomeFetchKeepsRenamedAndCancelledSavedEventsAndUpdatesCachedKeys() async {
        let original = snapshot(start: start, occurrence: start, id: "changed")
        let cancelledOriginal = snapshot(start: start, occurrence: start, id: "cancelled")
        let renamed = snapshot(start: start, occurrence: start, id: "changed", title: "Travel plans changed")
        let cancelled = snapshot(start: start, occurrence: start, id: "cancelled", cancelled: true, title: "Cancelled")
        let unrelated = snapshot(start: start, occurrence: start, id: "other", title: "Team meeting")
        let client = CalendarImportTestClient(snapshots: [renamed, cancelled, unrelated])
        let store = CalendarSuggestionStore(client: client, preferences: CalendarImportPreferences(defaults: nil), defaults: nil)
        let plans = [original, cancelledOriginal].map { savedPlan(source: $0.importSource) }
        let keys = Set(plans.compactMap { $0.calendarSource?.eventKey })
        await store.enable(includingEventKeys: [original.importSource.eventKey])
        XCTAssertEqual(store.changedSavedEvents(savedPlans: plans).map(\.id), [renamed.importSource.eventKey])
        await store.refreshIfStale(includingEventKeys: keys)
        XCTAssertEqual(Set(store.changedSavedEvents(savedPlans: plans).map(\.id)), keys)
        XCTAssertTrue(store.candidates(savedPlans: plans).isEmpty)
        await store.refresh(includingEventKeys: keys)
        let reads = await client.includedEventKeys
        XCTAssertEqual(reads, [[original.importSource.eventKey], keys, keys])
    }

    func testLegacyKeyedSavedJourneyHidesItsSuggestionAndSurfacesChanges() async {
        let current = candidate(id: "legacy-saved")
        let legacy = current.snapshot.legacyImportSource
        let saved = savedPlan(source: CalendarJourneySource(eventKey: legacy.eventKey, revision: "an-older-revision"))
        let store = await enabledStore(with: [current])
        XCTAssertTrue(store.candidates(savedPlans: [saved]).isEmpty)
        XCTAssertEqual(store.changedSavedEvents(savedPlans: [saved]).map(\.id), [current.id])
    }

    func testUnchangedSavedEventIsNotReportedAsChangedButCancelledOneIs() async {
        let unchanged = candidate(id: "unchanged")
        let cancelled = candidate(id: "cancelled", cancelled: true)
        let store = await enabledStore(with: [unchanged, cancelled])
        let plans = [unchanged, cancelled].map {
            savedPlan(source: $0.snapshot.importSource)
        }
        XCTAssertEqual(store.changedSavedEvents(savedPlans: plans).map(\.id), [cancelled.id])
    }

    func testDismissalMadeWithALegacyRevisionStillHolds() async throws {
        let suite = "CalendarSuggestionReliabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let floating = CalendarJourneyCandidate(snapshot: snapshot(start: start, occurrence: start, zone: nil), classification: classification())
        let legacy = floating.snapshot.legacyImportSource
        defaults.set([legacy.eventKey + ":" + legacy.revision], forKey: "calendarSuggestions.v1.dismissed")
        defaults.set(true, forKey: "calendarSuggestions.v1.enabled")
        let client = CalendarImportTestClient(fetchResult: .success([floating]))
        let store = CalendarSuggestionStore(client: client, preferences: CalendarImportPreferences(defaults: nil), defaults: defaults)
        await store.refresh()
        XCTAssertTrue(store.candidates(savedPlans: []).isEmpty)
    }

    func testJourneySavedUnderALegacyKeyMovesToTheStableKeyWhenItsEventIsRead() throws {
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = RecordingJourneyPlanArchive()
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let event = candidate(id: "migrating")
        let legacy = event.snapshot.legacyImportSource
        let base = JourneyPlanTestFixtures.makeDraft(id: UUID())
        let saved = try library.track(
            draft: JourneyPlanDraft(
                id: base.id, origin: base.origin, destination: base.destination,
                outbound: base.outbound, returnOption: nil,
                calendarSource: CalendarJourneySource(eventKey: legacy.eventKey, revision: legacy.revision)
            ),
            resolution: JourneyPlanTestFixtures.makeResolution(outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]])
        )

        library.adoptStableCalendarKeys(for: [event])

        let migrated = try XCTUnwrap(library.plans.first { $0.id == saved.id })
        XCTAssertEqual(migrated.calendarSource?.eventKey, event.snapshot.importSource.eventKey)
        XCTAssertEqual(migrated.calendarSource?.revision, legacy.revision, "The saved revision is kept")
        let reloaded = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        XCTAssertEqual(reloaded.plans.first?.calendarSource?.eventKey, event.snapshot.importSource.eventKey)
    }

    // MARK: Shared options

    func testEachReadPicksUpOptionsSavedByAnotherStore() async throws {
        let suite = "CalendarSuggestionReliabilityTests.options.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CalendarImportPreferences(defaults: defaults)
        let client = CalendarImportTestClient(fetchResult: .success([]))
        let suggestions = CalendarImportStore(client: client, preferences: preferences)
        XCTAssertNil(suggestions.options.selectedCalendarIDs)

        var edited = CalendarImportOptions()
        edited.selectedCalendarIDs = ["travel-only"]
        try preferences.save(edited)
        await suggestions.refresh()
        XCTAssertEqual(suggestions.options.selectedCalendarIDs, ["travel-only"])
    }

    // MARK: Keywords

    func testTrainMentionedOnlyInNotesNeedsARouteOrNumber() {
        XCTAssertNil(TicketRouteTextHeuristics.match(title: "Dinner with Sam", supportingText: ["Meet by the train station"]))
        let routed = TicketRouteTextHeuristics.match(title: "Weekend away", supportingText: ["Train: Boston to New York"])
        XCTAssertEqual(routed?.originGuess, "Boston")
        XCTAssertNotNil(TicketRouteTextHeuristics.match(title: "Train to Boston", supportingText: []))
    }

    // MARK: Multi-leg

    func testConnectingLegsReadAsFirstDepartureToLastArrival() {
        let notes = """
        From: Washington Union Station
        To: New York Penn Station
        From: New York Penn Station
        To: Boston South Station
        """
        let route = TicketRouteTextParser.extract(from: notes)
        XCTAssertEqual(route?.origin, "Washington Union Station")
        XCTAssertEqual(route?.destination, "Boston South Station")
    }

    func testRoundTripLegsUseTheOutboundLeg() {
        let notes = """
        From: Paris Gare du Nord
        To: London St Pancras
        From: London St Pancras
        To: Paris Gare du Nord
        """
        let route = TicketRouteTextParser.extract(from: notes)
        XCTAssertEqual(route?.origin, "Paris Gare du Nord")
        XCTAssertEqual(route?.destination, "London St Pancras")
    }

    func testLegsThatDoNotConnectStayUnparsed() {
        let notes = """
        From: Washington Union Station
        To: New York Penn Station
        From: Chicago Union Station
        To: Milwaukee
        """
        XCTAssertNil(TicketRouteTextParser.extract(from: notes))
    }

    // MARK: Helpers

    private func enabledStore(with candidates: [CalendarJourneyCandidate]) async -> CalendarSuggestionStore {
        let client = CalendarImportTestClient(fetchResult: .success(candidates))
        let store = CalendarSuggestionStore(client: client, preferences: CalendarImportPreferences(defaults: nil), defaults: nil)
        await store.enable()
        return store
    }

    private func snapshot(
        start: Date, occurrence: Date?, recurring: Bool = false, zone: String? = "America/New_York",
        id: String = "event-1", calendar: String = "Travel", cancelled: Bool = false,
        title: String = "Amtrak Boston to New York", location: String? = nil
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: id, calendarTitle: calendar, title: title,
            notes: nil, location: location, startDate: start, endDate: start.addingTimeInterval(4 * 3_600),
            isAllDay: false, timeZoneIdentifier: zone, isCancelled: cancelled,
            occurrenceDate: occurrence, isRecurring: recurring
        )
    }

    private func allDaySnapshot(year: Int, month: Int, day: Int) -> CalendarEventSnapshot {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = NSTimeZone.default
        let midnight = local.date(from: DateComponents(year: year, month: month, day: day))!
        return CalendarEventSnapshot(
            eventIdentifier: "all-day", calendarTitle: "Travel", title: "Amtrak travel day",
            notes: nil, location: nil, startDate: midnight, endDate: midnight.addingTimeInterval(86_399),
            isAllDay: true, timeZoneIdentifier: nil, occurrenceDate: midnight
        )
    }

    private func candidate(id: String, calendar: String = "Travel", cancelled: Bool = false) -> CalendarJourneyCandidate {
        CalendarJourneyCandidate(
            snapshot: snapshot(start: start, occurrence: start, id: id, calendar: calendar, cancelled: cancelled),
            classification: classification()
        )
    }

    private func classification() -> CalendarJourneyClassification {
        CalendarJourneyClassification(
            confidence: .high, evidence: ["Amtrak"], originGuess: "Boston",
            destinationGuess: "New York", trainNumberGuess: nil
        )
    }

    private func savedPlan(
        origin: String = "Boston", destination: String = "New York",
        departure: Date? = nil, source: CalendarJourneySource? = nil, service: String? = nil
    ) -> TrackedJourneyPlan {
        let tripID = RailIdentifier(rawValue: "us:amtrak:\(UUID().uuidString)")
        return TrackedJourneyPlan(
            id: UUID(), createdAt: start,
            origin: place(origin), destination: place(destination),
            outbound: JourneyPlanDirection(
                fingerprint: UUID().uuidString, departure: departure ?? start,
                arrival: (departure ?? start).addingTimeInterval(4 * 3_600), childTripIDs: [tripID],
                selectedSegments: service.map { [JourneyPlanSegment(id: "leg", kind: .rail, from: place(origin), to: place(destination), serviceName: $0)] }
            ),
            returnDirection: nil, preExistingChildTripIDs: [], calendarSource: source
        )
    }

    private func place(_ name: String) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: "us:place:\(name)"), kind: .station, displayName: name,
            context: "United States", countryCode: "US", timeZoneIdentifier: "America/New_York",
            location: GeoCoordinate(latitude: 40, longitude: -74), eligibleModes: ["rail"], attributions: []
        )
    }
}
