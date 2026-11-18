import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneySearchCalendarSourceTests: XCTestCase {
    @MainActor
    func testSkippedSpringHourRequestsACorrectionBeforeSearching() async throws {
        let ny = JourneySearchStoreFixtures.place(id: "us:nyp", name: "New York Penn", kind: .station, country: "US", timeZone: "America/New_York")
        let dc = JourneySearchStoreFixtures.place(id: "us:was", name: "Washington Union", kind: .station, country: "US", timeZone: "America/New_York")
        let suggestion = TicketRouteSuggestion(
            sourceDescription: "QA", originGuess: ny.displayName, destinationGuess: dc.displayName,
            calendarSource: CalendarJourneySource(eventKey: "spring-departure", revision: "first"),
            departureWallClock: TicketWallClock(year: 2027, month: 3, day: 14, hour: 2, minute: 30)
        )
        let client = ScriptedJourneySearchClient(places: [.success([ny]), .success([dc])])
        let store = SmartJourneyReviewStore(suggestion: suggestion, client: client, planTracker: RecordingJourneyPlanTracker(), plans: { [] },
                                            now: { Date(timeIntervalSince1970: 0) })
        store.start()
        await waitUntil { store.stage == .details(.invalidLocalTime) }
        XCTAssertEqual(store.stage, .details(.invalidLocalTime))
        XCTAssertTrue(store.visibleFields.contains(.time))
        XCTAssertNil(store.makeRequest())
        store.setTime(hour: 3, minute: 30)
        XCTAssertTrue(store.canBeginMatching)
        XCTAssertEqual(store.stage, .details(nil))
    }

    @MainActor
    func testFloatingCalendarDepartureResolvesAtBoardingStationAndKeepsCalendarLink() async throws {
        let clock = TicketWallClock(year: 2027, month: 1, day: 20, hour: 8, minute: 0)
        let source = CalendarJourneySource(eventKey: "floating", revision: "first")
        let dayZone = try XCTUnwrap(TimeZone(identifier: "Africa/Cairo"))
        let eastCoast = JourneySearchStoreFixtures.place(
            id: "us:nyp", name: "New York Penn", kind: .station, country: "US", timeZone: "America/New_York"
        )
        let destination = JourneySearchStoreFixtures.place(
            id: "us:was", name: "Washington Union", kind: .station, country: "US", timeZone: "America/New_York"
        )
        let suggestion = TicketRouteSuggestion(
            sourceDescription: "QA", originGuess: eastCoast.displayName, destinationGuess: destination.displayName,
            trainNumberGuess: "171", departureDate: clock.date(in: dayZone), calendarSource: source,
            departureWallClock: clock, isAllDayEvent: false, originPlace: eastCoast, destinationPlace: destination
        )
        let client = ScriptedJourneySearchClient()
        let store = SmartJourneyReviewStore(suggestion: suggestion, client: client, planTracker: RecordingJourneyPlanTracker(), plans: { [] })
        let request = try XCTUnwrap(store.makeRequest())
        XCTAssertEqual(request.departureTime, "2027-01-20T08:00:00")
        let result = try await ImportedJourneyPrefill.resolve(request, using: client)
        let expected = JourneySearchStoreFixtures.date("2027-01-20T13:00:00Z")
        XCTAssertEqual(result.departureTime, expected)
        let saved = try XCTUnwrap(result.calendarSource)
        XCTAssertEqual(saved.eventKey, source.eventKey)
        XCTAssertEqual(saved.revision, source.revision)
        XCTAssertEqual(saved.details?.departureDate, expected)
        XCTAssertEqual(saved.details?.boardingTimeZoneIdentifier, "America/New_York")
        XCTAssertNil(saved.details?.timeZoneIdentifier)
    }

    @MainActor
    func testManualAllDayTimeSurvivesDatePickerAndDraftRelaunchBeforeStationLookup() async throws {
        let source = CalendarJourneySource(eventKey: "all-day", revision: "first")
        let base = TicketRouteSuggestion(
            sourceDescription: "QA", requiresDepartureTime: true, calendarSource: source,
            departureWallClock: TicketWallClock(year: 2027, month: 1, day: 20), isAllDayEvent: true
        )
        let pickerValue = JourneySearchStoreFixtures.date("2027-01-20T08:00:00Z")
        let edited = base.requestFromDatePicker(origin: "New York Penn", destination: "Washington Union", trainNumber: "171", value: pickerValue)
        let reviewed = TicketRouteSuggestion(reviewed: edited, from: base)
        let reopened = try JSONDecoder().decode(TicketRouteSuggestion.self, from: JSONEncoder().encode(reviewed))
        let ny = JourneySearchStoreFixtures.place(id: "us:nyp", name: "New York Penn", kind: .station, country: "US", timeZone: "America/New_York")
        let dc = JourneySearchStoreFixtures.place(id: "us:was", name: "Washington Union", kind: .station, country: "US", timeZone: "America/New_York")
        let client = ScriptedJourneySearchClient(places: [.success([ny]), .success([dc])])
        let store = SmartJourneyReviewStore(suggestion: reopened, client: client, planTracker: RecordingJourneyPlanTracker(), plans: { [] })
        XCTAssertFalse(store.requiresTimeCheck, "The rider already confirmed a departure time")
        let result = try await ImportedJourneyPrefill.resolve(try XCTUnwrap(store.makeRequest()), using: client)
        XCTAssertEqual(result.departureTime, JourneySearchStoreFixtures.date("2027-01-20T13:00:00Z"))
        XCTAssertEqual(result.calendarSource?.details?.isAllDay, true)
        XCTAssertEqual(result.calendarSource?.eventKey, source.eventKey)
    }

    @MainActor
    func testCalendarSourceSurvivesReviewThenClearsForFollowingManualSearch() async throws {
        let option = journeyOutboundOption()
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [option])),
                .success(JourneySearchStoreFixtures.page(options: [option])),
            ]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())

        await store.prefillTicketJourney(request(source: source))
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertEqual(try XCTUnwrap(store.reviewDraftForTracking).calendarSource, source)

        store.finishTrackingPersistence(planID: UUID())
        XCTAssertNil(store.preferredTrainNumber)
        XCTAssertNil(store.reviewDraftForTracking?.calendarSource)

        store.editSearch()
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertNil(try XCTUnwrap(store.reviewDraftForTracking).calendarSource)
    }

    @MainActor
    func testShareImportReplacesPreviousCalendarProvenance() async throws {
        let option = journeyOutboundOption()
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [
                .success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam]),
                .success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam]),
            ],
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [option])),
                .success(JourneySearchStoreFixtures.page(options: [option])),
            ]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request(source: source))
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertEqual(try XCTUnwrap(store.reviewDraftForTracking).calendarSource, source)

        await store.prefillTicketJourney(request(source: nil))
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)
        XCTAssertNil(try XCTUnwrap(store.reviewDraftForTracking).calendarSource)
    }

    @MainActor
    func testChangingResolvedRouteClearsCalendarProvenance() async throws {
        let imported = journeyOutboundOption()
        let lyon = JourneySearchStoreFixtures.place(id: "lyon", name: "Lyon")
        let manual = JourneySearchStoreFixtures.option(
            id: "manual", fingerprint: "manual", start: imported.startTime, end: imported.endTime,
            destination: lyon
        )
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [
                .success(JourneySearchStoreFixtures.page(options: [imported])),
                .success(JourneySearchStoreFixtures.page(options: [manual])),
            ]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request(source: source))
        await waitUntil { store.phase == .showingOutbound }

        store.setDestination(lyon)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(manual)

        XCTAssertNil(try XCTUnwrap(store.reviewDraftForTracking).calendarSource)
    }

    @MainActor
    func testCorrectingUnresolvedEndpointRetainsCalendarProvenance() async throws {
        let option = journeyOutboundOption()
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash")
        let client = ScriptedJourneySearchClient(
            places: [.success([]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [.success(JourneySearchStoreFixtures.page(options: [option]))]
        )
        let store = makeJourneySearchStore(client: client, form: JourneySearchFormState())
        await store.prefillTicketJourney(request(source: source))
        XCTAssertEqual(store.phase, .editing)
        XCTAssertNil(store.form.origin)

        store.setOrigin(JourneySearchStoreFixtures.paris)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(option)

        XCTAssertEqual(try XCTUnwrap(store.reviewDraftForTracking).calendarSource, source)
    }

    private func request(source: CalendarJourneySource?) -> TicketJourneySearchRequest {
        TicketJourneySearchRequest(
            originName: "Paris", destinationName: "Amsterdam",
            departureTime: "2026-07-24T06:25:00Z", trainNumber: "9315", calendarSource: source
        )
    }
}
