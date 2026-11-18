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

    func testTripAlreadySavedByHandIsNotSuggested() async {
        let suggestion = candidate(id: "manual-duplicate")
        let store = await enabledStore(with: [suggestion])
        let manual = savedPlan(origin: "Boston South Station", destination: "New York Penn Station",
                               departure: start.addingTimeInterval(20 * 60))
        XCTAssertTrue(store.candidates(savedPlans: [manual]).isEmpty)
        let otherDay = savedPlan(origin: "Boston", destination: "New York", departure: start.addingTimeInterval(86_400))
        XCTAssertEqual(store.candidates(savedPlans: [otherDay]).map(\.id), [suggestion.id])
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
        id: String = "event-1", calendar: String = "Travel", cancelled: Bool = false
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: id, calendarTitle: calendar, title: "Amtrak Boston to New York",
            notes: nil, location: nil, startDate: start, endDate: start.addingTimeInterval(4 * 3_600),
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
        departure: Date? = nil, source: CalendarJourneySource? = nil
    ) -> TrackedJourneyPlan {
        let tripID = RailIdentifier(rawValue: "us:amtrak:\(UUID().uuidString)")
        return TrackedJourneyPlan(
            id: UUID(), createdAt: start,
            origin: place(origin), destination: place(destination),
            outbound: JourneyPlanDirection(
                fingerprint: UUID().uuidString, departure: departure ?? start,
                arrival: (departure ?? start).addingTimeInterval(4 * 3_600), childTripIDs: [tripID]
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
