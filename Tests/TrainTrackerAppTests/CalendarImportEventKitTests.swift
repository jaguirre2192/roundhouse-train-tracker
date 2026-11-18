import EventKit
import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

/// Opt-in through simulator privacy setup. The test never prompts and only writes/deletes
/// its own uniquely named calendar on a local source; synced calendars are never modified.
@MainActor
final class CalendarImportEventKitTests: XCTestCase {
    func testRealEventKitImportPreservesMetadataOccurrencesAndRenamedEvents() async throws {
        #if targetEnvironment(simulator)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Requires Calendar full access already granted to the simulator test host; this test never requests permission.")
        }
        let seedStore = EKEventStore()
        guard let localSource = seedStore.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("The simulator has no local EventKit source; the test will not create fixtures in a synced calendar.")
        }

        let calendarTitle = "Train Tracker QA Calendar Import \(UUID().uuidString)"
        let qaCalendar = EKCalendar(for: .event, eventStore: seedStore)
        qaCalendar.title = calendarTitle
        qaCalendar.source = localSource
        try seedStore.saveCalendar(qaCalendar, commit: true)
        let createdCalendarID = qaCalendar.calendarIdentifier
        defer {
            // Resolve only the exact calendar this invocation created, even after refreshes.
            if let ownedCalendar = seedStore.calendar(withIdentifier: createdCalendarID) {
                if ownedCalendar.title == calendarTitle, ownedCalendar.source.sourceType == .local {
                    do {
                        try seedStore.removeCalendar(ownedCalendar, commit: true)
                    } catch {
                        XCTFail("Could not remove the temporary QA calendar: \(error.localizedDescription)")
                    }
                } else {
                    XCTFail("Temporary QA calendar ownership changed; cleanup did not modify it.")
                }
            }
        }

        var dates = Calendar(identifier: .gregorian)
        dates.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let day = try XCTUnwrap(dates.date(from: DateComponents(year: 2032, month: 2, day: 10)))
        let normalStart = day.addingTimeInterval(8.5 * 3_600)
        let recurringStart = day.addingTimeInterval(16 * 3_600)
        let normalTitle = "Amtrak 176: Washington, DC → New York, NY"
        let recurringTitle = "Eurostar 9032 London→Paris"
        let allDayTitle = "Amtrak travel date"
        let outsideTitle = "Amtrak 179 Boston to New York"

        let normal = try seedEvent(
            in: seedStore, calendar: qaCalendar, title: normalTitle,
            start: normalStart, duration: 3 * 3_600, timeZone: dates.timeZone
        )
        let normalEventID = try XCTUnwrap(normal.eventIdentifier)
        _ = try seedEvent(
            in: seedStore, calendar: qaCalendar, title: allDayTitle,
            start: day, duration: 86_400, timeZone: dates.timeZone, allDay: true,
            notes: "Departure: Washington Union Station\nArrival: New York Penn Station"
        )
        _ = try seedEvent(
            in: seedStore, calendar: qaCalendar, title: recurringTitle,
            start: recurringStart, duration: 2 * 3_600, timeZone: dates.timeZone,
            recurrence: EKRecurrenceRule(
                recurrenceWith: .daily, interval: 1,
                end: EKRecurrenceEnd(occurrenceCount: 2)
            )
        )
        _ = try seedEvent(
            in: seedStore, calendar: qaCalendar, title: outsideTitle,
            start: day.addingTimeInterval(5 * 86_400), duration: 3_600, timeZone: dates.timeZone
        )

        let client = CalendarImportClient()
        // Pad the start for EventKit's local-midnight normalization of all-day events.
        let window = DateInterval(start: day.addingTimeInterval(-86_400), end: day.addingTimeInterval(3 * 86_400))
        let candidates = try await client.fetchCandidates(window: window)
            .filter { $0.snapshot.calendarTitle == calendarTitle }
        XCTAssertEqual(candidates.count, 4, "One timed event, one all-day event, and two recurring occurrences must be imported.")
        XCTAssertFalse(candidates.contains { $0.snapshot.title == outsideTitle })
        XCTAssertEqual(candidates.map(\.snapshot.startDate), candidates.map(\.snapshot.startDate).sorted())

        let calendars = try await client.fetchCalendars()
        XCTAssertEqual(calendars.first { $0.id == createdCalendarID }?.title, calendarTitle)
        let selected = try await client.fetchCandidates(window: window, selectedCalendarIDs: [createdCalendarID])
        XCTAssertEqual(Set(selected.map(\.id)), Set(candidates.map(\.id)))
        let noCalendars = try await client.fetchCandidates(window: window, selectedCalendarIDs: [])
        XCTAssertTrue(noCalendars.isEmpty, "An empty selection must not query every calendar.")
        let unavailableCalendar = try await client.fetchCandidates(window: window, selectedCalendarIDs: [UUID().uuidString])
        XCTAssertTrue(unavailableCalendar.isEmpty, "Unavailable calendar IDs must not fall back to every calendar.")

        let timed = try XCTUnwrap(candidates.first { $0.snapshot.title == normalTitle })
        XCTAssertEqual(timed.classification.originGuess, "Washington, DC")
        XCTAssertEqual(timed.classification.destinationGuess, "New York, NY")
        XCTAssertEqual(timed.classification.trainNumberGuess, "176")
        XCTAssertEqual(timed.classification.confidence, .high)
        XCTAssertEqual(timed.snapshot.startDate, normalStart)
        XCTAssertEqual(timed.snapshot.endDate, normalStart.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(timed.snapshot.timeZoneIdentifier, "America/New_York")
        XCTAssertFalse(timed.snapshot.isAllDay)

        let allDay = try XCTUnwrap(candidates.first { $0.snapshot.title == allDayTitle })
        XCTAssertTrue(allDay.snapshot.isAllDay)
        XCTAssertTrue(allDay.routeSuggestion.requiresDepartureTime)
        XCTAssertEqual(allDay.classification.originGuess, "Washington Union Station")
        XCTAssertEqual(allDay.classification.destinationGuess, "New York Penn Station")

        let occurrences = candidates.filter { $0.snapshot.title == recurringTitle }
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(Set(occurrences.map(\.id)).count, 2, "Recurring occurrences must have distinct import identities.")
        XCTAssertEqual(
            Set(occurrences.compactMap(\.snapshot.occurrenceDate)),
            Set([recurringStart, recurringStart.addingTimeInterval(86_400)])
        )
        for occurrence in occurrences {
            XCTAssertEqual(occurrence.classification.originGuess, "London")
            XCTAssertEqual(occurrence.classification.destinationGuess, "Paris")
            XCTAssertEqual(occurrence.classification.trainNumberGuess, "9032")
            XCTAssertEqual(occurrence.snapshot.timeZoneIdentifier, "America/New_York")
        }

        let renamedEvent = try XCTUnwrap(seedStore.event(withIdentifier: normalEventID))
        renamedEvent.title = "QA plans changed"
        try seedStore.save(renamedEvent, span: .thisEvent, commit: true)

        let fresh = try await client.fetchCandidates(window: window)
            .filter { $0.snapshot.calendarTitle == calendarTitle }
        XCTAssertFalse(fresh.contains { $0.id == timed.id }, "A fresh scan must observe the renamed title without train evidence.")
        XCTAssertEqual(Set(fresh.filter { $0.snapshot.title == recurringTitle }.map(\.id)), Set(occurrences.map(\.id)))

        let retained = try await client.fetchCandidates(window: window, includingEventKeys: [timed.id])
            .filter { $0.snapshot.calendarTitle == calendarTitle }
        let renamed = try XCTUnwrap(retained.first { $0.id == timed.id })
        XCTAssertEqual(renamed.snapshot.title, "QA plans changed")
        XCTAssertEqual(renamed.classification.evidence, ["Previously imported calendar event"])
        XCTAssertNotEqual(renamed.snapshot.importSource.revision, timed.snapshot.importSource.revision)

        let emptyWindow = DateInterval(start: day.addingTimeInterval(3 * 86_400), duration: 86_400)
        let outsideWindow = try await client.fetchCandidates(window: emptyWindow, includingEventKeys: [timed.id])
            .filter { $0.snapshot.calendarTitle == calendarTitle }
        XCTAssertTrue(outsideWindow.isEmpty, "Retaining an imported identity must not bypass the requested date window.")
        #else
        throw XCTSkip("Calendar import integration fixtures are permitted only in an iOS simulator.")
        #endif
    }

    /// Rescheduling a one-off trip must keep the same import identity, so the saved journey
    /// stays linked and the importer reports it as changed rather than as a new event.
    func testMovingASingleEventKeepsItsImportKey() async throws {
        #if targetEnvironment(simulator)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Requires Calendar full access already granted to the simulator test host; this test never requests permission.")
        }
        let store = EKEventStore()
        guard let localSource = store.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("The simulator has no local EventKit source; the test will not create fixtures in a synced calendar.")
        }
        let calendarTitle = "Train Tracker QA Reschedule \(UUID().uuidString)"
        let qaCalendar = EKCalendar(for: .event, eventStore: store)
        qaCalendar.title = calendarTitle
        qaCalendar.source = localSource
        try store.saveCalendar(qaCalendar, commit: true)
        let calendarID = qaCalendar.calendarIdentifier
        defer {
            if let owned = store.calendar(withIdentifier: calendarID), owned.title == calendarTitle,
               owned.source.sourceType == .local {
                try? store.removeCalendar(owned, commit: true)
            }
        }

        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var dates = Calendar(identifier: .gregorian)
        dates.timeZone = zone
        let day = try XCTUnwrap(dates.date(from: DateComponents(year: 2032, month: 3, day: 9)))
        let event = try seedEvent(
            in: store, calendar: qaCalendar, title: "Amtrak 171 New York Penn → Washington Union",
            start: day.addingTimeInterval(14 * 3_600), duration: 3 * 3_600, timeZone: zone
        )
        let window = DateInterval(start: day.addingTimeInterval(-86_400), end: day.addingTimeInterval(4 * 86_400))
        let client = CalendarImportClient()
        let beforeCandidates = try await client.fetchCandidates(window: window)
        let before = try XCTUnwrap(beforeCandidates.first { $0.snapshot.calendarTitle == calendarTitle })

        event.startDate = event.startDate.addingTimeInterval(86_400 + 1_800)
        event.endDate = event.endDate.addingTimeInterval(86_400 + 1_800)
        try store.save(event, span: .thisEvent, commit: true)

        let afterCandidates = try await client.fetchCandidates(window: window)
        let after = try XCTUnwrap(afterCandidates.first { $0.snapshot.calendarTitle == calendarTitle })
        XCTAssertEqual(after.snapshot.importSource.eventKey, before.snapshot.importSource.eventKey,
                       "A rescheduled one-off event must keep its identity")
        XCTAssertNotEqual(after.snapshot.importSource.revision, before.snapshot.importSource.revision,
                          "The move must still read as a change")
        #else
        throw XCTSkip("Uses the simulator's local EventKit source.")
        #endif
    }

    func testReviewingAnOvernightCalendarTrainSavesItsStopsAndSourceOnlyAfterConfirmation() async throws {
        #if targetEnvironment(simulator)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Grant Calendar full access to the simulator test host to run this integration.")
        }
        let eventStore = EKEventStore()
        guard let local = eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("Requires a local simulator calendar source for the temporary fixture.")
        }
        let title = "Roundhouse QA Overnight \(UUID().uuidString)"
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = title
        calendar.source = local
        try eventStore.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier
        defer {
            if let owned = eventStore.calendar(withIdentifier: calendarID),
               owned.title == title, owned.source.sourceType == .local {
                XCTAssertNoThrow(try eventStore.removeCalendar(owned, commit: true))
            }
        }

        // The synthetic timetable crosses both midnight and the change from CEST to CET.
        let start = JourneySearchStoreFixtures.date("2027-10-30T21:55:00Z")
        let end = JourneySearchStoreFixtures.date("2027-10-31T03:35:00Z")
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        _ = try seedEvent(in: eventStore, calendar: calendar, title: "Eurostar 9315 Paris → Amsterdam",
                          start: start, duration: end.timeIntervalSince(start), timeZone: zone)

        let context = try JourneyPlanTestFixtures.makeTripLibrary(now: { start })
        defer { context.cleanup() }
        let preferences = CalendarImportPreferences(defaults: context.defaults)
        try preferences.save(CalendarImportOptions(selectedCalendarIDs: [calendarID]))
        let importer = CalendarImportStore(preferences: preferences, window: {
            DateInterval(start: start.addingTimeInterval(-3600), end: end)
        })
        await importer.beginImport()
        guard case let .loaded(candidates) = importer.state else { return XCTFail("The seeded calendar was not imported") }
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertTrue(CalendarCandidateActionPolicy.canFindDirectly(candidate))

        let trip = overnightTrip(start: start, end: end)
        let option = JourneySearchStoreFixtures.option(id: "overnight", fingerprint: "overnight",
                                                      start: start, end: end, tripID: trip.id.rawValue)
        let resolution = JourneySearchStoreFixtures.resolution(outbound: option, outboundTrips: [trip])
        let provider = ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [.success(JourneySearchStoreFixtures.page(options: [option]))], resolutions: [.success(resolution)]
        )
        let archive = JourneyPlanArchive(defaults: context.defaults)
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        let review = SmartJourneyReviewStore(suggestion: candidate.routeSuggestion, client: provider,
                                             planTracker: library, plans: { library.plans },
                                             now: { start.addingTimeInterval(-3600) })
        review.start()
        await waitUntil { review.search.phase == .reviewing }
        let request = await provider.journeyRequests.first
        XCTAssertEqual(request?.requestedTime, start)
        review.search.resolveSelection()
        await waitUntil { review.search.resolvedPlan != nil }
        XCTAssertTrue(library.plans.isEmpty)
        XCTAssertTrue(context.library.trips.isEmpty)
        XCTAssertTrue(review.search.trackResolvedPlan())

        guard case let .completed(id) = review.search.phase else { return XCTFail("Tracking did not complete") }
        let reopened = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)
        XCTAssertEqual(reopened.plans.count, 1)
        let saved = try XCTUnwrap(reopened.plan(importedFrom: candidate.id))
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.outbound.departure, start)
        XCTAssertEqual(saved.outbound.arrival, end)
        XCTAssertEqual(saved.calendarSource?.revision, candidate.snapshot.importSource.revision)
        XCTAssertEqual(saved.calendarSource?.details?.departureDate, start)
        XCTAssertEqual(saved.calendarSource?.details?.timeZoneIdentifier, zone.identifier)
        XCTAssertEqual(context.archive.load().map(\.stopTimes), [trip.stopTimes])
        XCTAssertEqual(CalendarImportDisposition(candidate: candidate, savedPlan: saved), .alreadyAdded)
        #else
        throw XCTSkip("Calendar import integration fixtures are permitted only in an iOS simulator.")
        #endif
    }

    #if targetEnvironment(simulator)
    private func overnightTrip(start: Date, end: Date) -> TrainTrip {
        func station(_ place: RailPlace) -> Station {
            Station(id: place.id, names: [LocalizedStationName(place.displayName)], location: place.location,
                    countryCode: place.countryCode, timeZoneIdentifier: place.timeZoneIdentifier)
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "eu:transitous:calendar-qa-9315"), source: "Transitous", serviceDate: start,
            operatorName: "Eurostar", product: "Eurostar 9315", headsign: "Amsterdam",
            stopTimes: [
                StopTime(station: station(JourneySearchStoreFixtures.paris), sequence: 0, scheduledDeparture: start),
                StopTime(station: station(JourneySearchStoreFixtures.amsterdam), sequence: 1, scheduledArrival: end)
            ],
            capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: false,
                                               hasAlerts: false, granularity: .tripOnly)
        )
    }

    private func seedEvent(
        in store: EKEventStore, calendar: EKCalendar, title: String,
        start: Date, duration: TimeInterval, timeZone: TimeZone,
        allDay: Bool = false, notes: String? = nil, recurrence: EKRecurrenceRule? = nil
    ) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.timeZone = timeZone
        event.startDate = start
        event.endDate = start.addingTimeInterval(duration)
        event.isAllDay = allDay
        event.notes = notes
        if let recurrence { event.recurrenceRules = [recurrence] }
        try store.save(event, span: .thisEvent, commit: true)
        return event
    }
    #endif
}
