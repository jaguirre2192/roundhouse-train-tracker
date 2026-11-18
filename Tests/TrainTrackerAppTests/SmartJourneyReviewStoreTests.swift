import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class SmartJourneyReviewStoreTests: XCTestCase {
    private let now = JourneySearchStoreFixtures.date("2026-07-21T12:00:00Z")
    /// 08:25 in Paris on 24 July is 06:25Z, the fixture's scheduled departure.
    private let parisClock = TicketWallClock(year: 2026, month: 7, day: 24, hour: 8, minute: 25)

    private func suggestion(
        id: UUID = UUID(),
        origin: String? = "Paris", destination: String? = "Amsterdam", number: String? = "9315",
        clock: TicketWallClock? = nil, requiresTime: Bool = false
    ) -> TicketRouteSuggestion {
        TicketRouteSuggestion(
            id: id, sourceDescription: "Shared text", originGuess: origin, destinationGuess: destination,
            trainNumberGuess: number, requiresDepartureTime: requiresTime, departureWallClock: clock ?? parisClock
        )
    }

    private func makeStore(
        _ suggestion: TicketRouteSuggestion, client: ScriptedJourneySearchClient,
        tracker: RecordingJourneyPlanTracker = RecordingJourneyPlanTracker(),
        plans: [TrackedJourneyPlan] = [], linked: Set<UUID> = []
    ) -> SmartJourneyReviewStore {
        SmartJourneyReviewStore(
            suggestion: suggestion, client: client, planTracker: tracker,
            plans: { plans }, linkedPlanIDs: linked, now: { [now] in now }
        )
    }

    private func places() -> [ScriptedJourneySearchClient.PlaceResponse] {
        [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])]
    }

    func testCompleteImportSearchesOnceAndOpensSingleTrackConfirmationWithoutSaving() async throws {
        let option = journeyOutboundOption()
        let later = journeyOutboundOption(id: "later", fingerprint: "later", start: JourneySearchStoreFixtures.date("2026-07-24T08:25:00Z"),
                                          end: JourneySearchStoreFixtures.date("2026-07-24T11:25:00Z"))
        let client = ScriptedJourneySearchClient(places: places(), pages: [.success(JourneySearchStoreFixtures.page(options: [later, option]))])
        let tracker = RecordingJourneyPlanTracker()
        let store = makeStore(suggestion(), client: client, tracker: tracker)

        store.start()
        XCTAssertEqual(store.stage, .matching)
        await waitUntil { store.search.phase == .reviewing }
        XCTAssertEqual(store.search.selectedOutbound, option)
        XCTAssertTrue(tracker.calls.isEmpty, "Matching never tracks without the confirmation")
        let requests = await client.journeyRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.requestedTime, JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"))
        let placeQueries = await client.placeRequests.map { $0.query }
        XCTAssertEqual(placeQueries, ["Paris", "Amsterdam"], "Only station names and time are sent")
    }

    func testTrackingFromReviewSavesOnceWithStableImportDraftID() async throws {
        let option = journeyOutboundOption()
        let resolution = JourneySearchStoreFixtures.resolution(outbound: option, outboundTrips: [JourneyPlanTestFixtures.makeTrips()[0]])
        let importID = UUID()
        let tracker = RecordingJourneyPlanTracker()
        let client = ScriptedJourneySearchClient(
            places: places() + places(),
            pages: [.success(JourneySearchStoreFixtures.page(options: [option])), .success(JourneySearchStoreFixtures.page(options: [option]))],
            resolutions: [.success(resolution)]
        )
        let store = makeStore(suggestion(id: importID), client: client, tracker: tracker)
        store.start()
        await waitUntil { store.search.phase == .reviewing }
        store.search.resolveSelection()
        await waitUntil { store.search.resolvedPlan != nil }
        XCTAssertTrue(store.search.trackResolvedPlan())
        guard case let .completed(planID) = store.search.phase else { return XCTFail("Expected completion") }
        XCTAssertEqual(tracker.calls.count, 1)
        XCTAssertTrue(store.wasCreated(planID: planID))
        XCTAssertEqual(planID, JourneyDraftIdentity.stableID(seed: importID, fingerprint: option.fingerprint))

        // A relaunched review of the same import selects the same journey with the same plan ID.
        let again = makeStore(suggestion(id: importID), client: client, tracker: tracker)
        again.start()
        await waitUntil { again.search.phase == .reviewing }
        XCTAssertEqual(again.search.reviewDraftForTracking?.id, planID)
        XCTAssertNotEqual(JourneyDraftIdentity.stableID(seed: UUID(), fingerprint: option.fingerprint), planID)
    }

    func testMissingTimeAsksOnlyForTimeAndRequiresExplicitCheckBeforeSearch() async {
        let client = ScriptedJourneySearchClient(places: places(), pages: [.success(JourneySearchStoreFixtures.page(options: [journeyOutboundOption()]))])
        let dayOnly = TicketWallClock(year: 2026, month: 7, day: 24)
        let store = makeStore(suggestion(clock: dayOnly, requiresTime: true), client: client)
        store.start()
        XCTAssertEqual(store.stage, .details(.missingDetails))
        XCTAssertEqual(store.missingFields, [.time])
        XCTAssertEqual(store.visibleFields, [.time])
        XCTAssertFalse(store.canBeginMatching)

        var saved: [TicketRouteSuggestion] = []
        store.onDraftChange = { saved.append($0) }
        store.setTime(hour: 8, minute: 25)
        XCTAssertEqual(store.missingFields, [.time], "A time the ticket did not print must be checked")
        store.setTimeChecked(true)
        XCTAssertTrue(store.canBeginMatching)
        XCTAssertEqual(saved.last?.departureWallClock, parisClock)
        XCTAssertEqual(saved.last?.requiresDepartureTime, false)
        let requests = await client.placeRequests
        XCTAssertTrue(requests.isEmpty, "Nothing is searched while details are missing")

        store.beginMatching()
        await waitUntil { store.search.phase == .reviewing }
    }

    func testMissingDateAndStationsNeverDefaultToToday() {
        let store = makeStore(
            TicketRouteSuggestion(sourceDescription: "Shared text", originGuess: nil, destinationGuess: nil),
            client: ScriptedJourneySearchClient()
        )
        store.start()
        XCTAssertEqual(store.missingFields, [.origin, .destination, .date, .time])
        XCTAssertNil(store.departure)
        XCTAssertNil(store.makeRequest())
    }

    func testSettingMissingDayKeepsDateVisibleForCorrection() {
        let store = makeStore(
            TicketRouteSuggestion(sourceDescription: "Shared text", originGuess: "Paris", destinationGuess: "Amsterdam"),
            client: ScriptedJourneySearchClient()
        )
        store.start()
        XCTAssertEqual(store.visibleFields, [.date, .time])
        store.setDay(year: 2026, month: 7, day: 24)
        XCTAssertFalse(store.missingFields.contains(.date))
        XCTAssertTrue(store.visibleFields.contains(.date))
        store.setDay(year: 2026, month: 7, day: 25)
        XCTAssertEqual(store.departure?.day, 25)
    }

    func testDifferentSelectedStationIDsWithSameNameAllowMatching() throws {
        let origin = JourneySearchStoreFixtures.place(id: "us:portland-or", name: "Portland", kind: .station)
        let destination = JourneySearchStoreFixtures.place(id: "us:portland-me", name: "Portland", kind: .station)
        let store = makeStore(suggestion(number: nil), client: ScriptedJourneySearchClient())
        store.selectStation(origin, for: .origin)
        store.selectStation(destination, for: .destination)
        XCTAssertTrue(store.canBeginMatching)
        let request = try XCTUnwrap(store.makeRequest())
        XCTAssertEqual(request.originPlace?.id, origin.id)
        XCTAssertEqual(request.destinationPlace?.id, destination.id)
    }

    func testSameSelectedStationIDWithDifferentNamesCannotMatch() {
        let origin = JourneySearchStoreFixtures.place(id: "us:portland", name: "Portland", kind: .station)
        let alias = JourneySearchStoreFixtures.place(id: "us:portland", name: "Portland Union Station", kind: .station)
        let store = makeStore(suggestion(), client: ScriptedJourneySearchClient())
        store.selectStation(origin, for: .origin)
        store.selectStation(alias, for: .destination)
        XCTAssertEqual(store.missingFields, [.destination])
        XCTAssertFalse(store.canBeginMatching)
    }

    func testPlaceholderDateAndTimeForUndatedImportStillRequireExplicitCheck() {
        let store = makeStore(
            TicketRouteSuggestion(sourceDescription: "Shared text", originGuess: "Paris", destinationGuess: "Amsterdam"),
            client: ScriptedJourneySearchClient()
        )
        store.start()
        XCTAssertTrue(store.requiresTimeCheck)
        store.setDay(year: 2026, month: 7, day: 24)
        store.setTime(hour: 9, minute: 0)
        XCTAssertEqual(store.missingFields, [.time], "A placeholder time is never treated as the ticket's time")
        XCTAssertFalse(store.canBeginMatching)
        store.setTimeChecked(true)
        XCTAssertTrue(store.canBeginMatching)
    }

    func testAllDayCalendarEventKeepsAllDayFlagAfterTimeIsChecked() {
        let suggestion = TicketRouteSuggestion(
            sourceDescription: "Travel", originGuess: "Paris", destinationGuess: "Amsterdam",
            departureDate: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z"), requiresDepartureTime: true,
            departureTimeZoneIdentifier: "Europe/Paris", calendarSource: CalendarJourneySource(eventKey: "e", revision: "r"),
            isAllDayEvent: true
        )
        let store = makeStore(suggestion, client: ScriptedJourneySearchClient())
        store.setTime(hour: 8, minute: 25)
        store.setTimeChecked(true)
        XCTAssertEqual(store.makeRequest()?.calendarSource?.details?.isAllDay, true)
        XCTAssertEqual(store.suggestion.isAllDayEvent, true)
    }

    func testAmbiguousMatchesShowDepartureChoices() async {
        let first = journeyOutboundOption(id: "one", fingerprint: "one")
        let second = journeyOutboundOption(id: "two", fingerprint: "two", start: JourneySearchStoreFixtures.date("2026-07-24T06:30:00Z"))
        let client = ScriptedJourneySearchClient(places: places(), pages: [.success(JourneySearchStoreFixtures.page(options: [first, second]))])
        let store = makeStore(suggestion(), client: client)
        store.start()
        await waitUntil { store.search.phase == .showingOutbound }
        XCTAssertEqual(store.search.importedReviewMessage, ImportedJourneyAutoSelection.Reason.ambiguous.message)
        store.search.selectOutbound(second)
        XCTAssertEqual(store.search.phase, .reviewing)
        XCTAssertTrue(store.search.canReturnToOutboundResults)
        store.search.returnToOutboundResults()
        XCTAssertEqual(store.search.phase, .showingOutbound)
    }

    func testUntrackableMatchIsNotPresentedAsTrackable() async {
        let untrackable = JourneySearchStoreFixtures.option(
            id: "c", fingerprint: "c", start: JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T09:25:00Z"), isTrackable: false, untrackableReason: "No stable train identity"
        )
        let client = ScriptedJourneySearchClient(places: places(), pages: [.success(JourneySearchStoreFixtures.page(options: [untrackable]))])
        let store = makeStore(suggestion(), client: client)
        store.start()
        await waitUntil { store.search.phase == .showingOutbound }
        XCTAssertNil(store.search.selectedOutbound)
        XCTAssertEqual(store.search.importedReviewMessage, ImportedJourneyAutoSelection.Reason.notFullyTrackable.message)
    }

    func testUnnumberedTicketMatchesOnlyExactDirectDepartureBetweenResolvedStations() async {
        let paris = JourneySearchStoreFixtures.place(id: "eu:paris-nord", name: "Paris Nord", kind: .station)
        let amsterdam = JourneySearchStoreFixtures.place(id: "eu:amsterdam-c", name: "Amsterdam Centraal", kind: .station, country: "NL", timeZone: "Europe/Amsterdam")
        let exact = JourneySearchStoreFixtures.option(id: "exact", fingerprint: "exact", start: JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"),
                                                       end: JourneySearchStoreFixtures.date("2026-07-24T09:25:00Z"), origin: paris, destination: amsterdam)
        let nearby = JourneySearchStoreFixtures.option(id: "near", fingerprint: "near", start: JourneySearchStoreFixtures.date("2026-07-24T06:30:00Z"),
                                                        end: JourneySearchStoreFixtures.date("2026-07-24T09:30:00Z"), origin: paris, destination: amsterdam)
        let client = ScriptedJourneySearchClient(
            places: [.success([paris]), .success([amsterdam])],
            pages: [.success(JourneySearchStoreFixtures.page(options: [nearby, exact]))]
        )
        let store = makeStore(suggestion(origin: "Paris Nord", destination: "Amsterdam Centraal", number: nil), client: client)
        store.start()
        await waitUntil { store.search.phase == .reviewing }
        XCTAssertEqual(store.search.selectedOutbound, exact)

        let offByFive = ImportedJourneyAutoSelection(trainNumber: nil, departure: JourneySearchStoreFixtures.date("2026-07-24T06:20:00Z"), origin: paris, destination: amsterdam)
        XCTAssertEqual(offByFive?.decision(in: [exact]), .choose(.noMatch))
        XCTAssertNil(ImportedJourneyAutoSelection(trainNumber: nil, departure: .now, origin: JourneySearchStoreFixtures.paris, destination: amsterdam),
                     "A city-level place is not enough for an unnumbered match")
    }

    func testNetworkFailureKeepsEnteredFieldsAndRetries() async {
        let client = ScriptedJourneySearchClient(
            places: [.failure(.unavailable)] + places(),
            pages: [.success(JourneySearchStoreFixtures.page(options: [journeyOutboundOption()]))]
        )
        let store = makeStore(suggestion(), client: client)
        store.start()
        await waitUntil { store.stage == .details(.lookupFailed) }
        XCTAssertEqual(store.origin, "Paris")
        XCTAssertEqual(store.departure, parisClock)
        store.retry()
        await waitUntil { store.search.phase == .reviewing }
    }

    func testUnmatchedStationShowsOnlyThatField() async {
        let client = ScriptedJourneySearchClient(places: [.success([JourneySearchStoreFixtures.paris]), .success([])])
        let store = makeStore(suggestion(destination: "Atlantis"), client: client)
        store.start()
        await waitUntil { store.stage == .details(.stationNotFound(origin: false, destination: true)) }
        XCTAssertEqual(store.visibleFields, [.destination])
    }

    func testPastDepartureIsShownBeforeAnySearch() async {
        let client = ScriptedJourneySearchClient()
        let store = makeStore(suggestion(clock: TicketWallClock(year: 2026, month: 7, day: 1, hour: 9, minute: 0)), client: client)
        store.start()
        XCTAssertEqual(store.stage, .details(.pastDeparture))
        let requests = await client.placeRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLinkedOrEquivalentSavedJourneyOpensInsteadOfSearching() async throws {
        let plan = savedPlan()
        let linked = makeStore(suggestion(), client: ScriptedJourneySearchClient(), plans: [plan], linked: [plan.id])
        linked.start()
        XCTAssertEqual(linked.stage, .existing(planID: plan.id))

        let equivalent = makeStore(suggestion(), client: ScriptedJourneySearchClient(), plans: [plan])
        equivalent.start()
        XCTAssertEqual(equivalent.stage, .existing(planID: plan.id), "Same stations, time and train number")

        let otherTrain = makeStore(suggestion(number: "9999"), client: ScriptedJourneySearchClient(places: places()), plans: [plan])
        XCTAssertNil(otherTrain.existingPlan())
        XCTAssertEqual(otherTrain.existingPlan(forSelected: journeyOutboundOption(fingerprint: plan.outbound.fingerprint))?.id, plan.id)
    }

    func testChangedCalendarRevisionContinuesToUpdateButSameRevisionIsAlreadyAdded() {
        let source = CalendarJourneySource(eventKey: "event", revision: "r1")
        let plan = savedPlan(calendarSource: source)
        let calendar = { (revision: String) in
            TicketRouteSuggestion(
                sourceDescription: "Travel", originGuess: "Paris", destinationGuess: "Amsterdam", trainNumberGuess: "9315",
                departureDate: JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"), departureTimeZoneIdentifier: "Europe/Paris",
                calendarSource: CalendarJourneySource(eventKey: "event", revision: revision)
            )
        }
        let same = makeStore(calendar("r1"), client: ScriptedJourneySearchClient(), plans: [plan])
        XCTAssertEqual(same.existingPlan()?.id, plan.id)
        let changed = makeStore(calendar("r2"), client: ScriptedJourneySearchClient(), plans: [plan])
        XCTAssertNil(changed.existingPlan())
        XCTAssertNil(changed.existingPlan(forSelected: journeyOutboundOption(fingerprint: plan.outbound.fingerprint)))
        XCTAssertEqual(changed.makeRequest()?.calendarSource?.revision, "r2")
        XCTAssertEqual(changed.makeRequest()?.departureTime, "2026-07-24T06:25:00Z")
    }

    func testRecognizedStationDraftCodableRoundTripRestoresExactChoices() throws {
        let origin = JourneySearchStoreFixtures.place(id: "fr:chosen-paris-nord", name: "Paris Nord", kind: .station)
        let destination = JourneySearchStoreFixtures.place(
            id: "nl:chosen-amsterdam-centraal", name: "Amsterdam Centraal", kind: .station,
            country: "NL", timeZone: "Europe/Amsterdam"
        )
        let store = makeStore(suggestion(), client: ScriptedJourneySearchClient())
        var savedDraft: TicketRouteSuggestion?
        store.onDraftChange = { savedDraft = $0 }
        store.selectStation(origin, for: .origin)
        store.selectStation(destination, for: .destination)

        let saved = try XCTUnwrap(savedDraft)
        let restored = try JSONDecoder().decode(TicketRouteSuggestion.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.id, store.suggestion.id)
        XCTAssertEqual(restored.originPlace, origin)
        XCTAssertEqual(restored.destinationPlace, destination)
        XCTAssertEqual(restored.departureWallClock, parisClock)

        let reopened = makeStore(restored, client: ScriptedJourneySearchClient())
        XCTAssertEqual(reopened.originPlace, origin)
        XCTAssertEqual(reopened.destinationPlace, destination)
        XCTAssertEqual(reopened.makeRequest()?.originPlace?.id, origin.id)
        XCTAssertEqual(reopened.makeRequest()?.destinationPlace?.id, destination.id)
    }

    func testExplicitStationChoicesBypassPlaceLookupDuringPrefill() async throws {
        let origin = JourneySearchStoreFixtures.place(id: "fr:chosen-paris-nord", name: "Paris Nord", kind: .station)
        let destination = JourneySearchStoreFixtures.place(
            id: "nl:chosen-amsterdam-centraal", name: "Amsterdam Centraal", kind: .station,
            country: "NL", timeZone: "Europe/Amsterdam"
        )
        let client = ScriptedJourneySearchClient()
        let store = makeStore(suggestion(number: nil), client: client)
        store.selectStation(origin, for: .origin)
        store.selectStation(destination, for: .destination)

        let request = try XCTUnwrap(store.makeRequest())
        let prefill = try await ImportedJourneyPrefill.resolve(request, using: client)
        XCTAssertEqual(prefill.origin, origin)
        XCTAssertEqual(prefill.destination, destination)
        XCTAssertEqual(prefill.departureTime, JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"))
        XCTAssertNotNil(prefill.directReview)
        let lookups = await client.placeRequests
        XCTAssertTrue(lookups.isEmpty, "Restored choices must use their IDs even when place lookup is unavailable")
    }

    func testEditingStationTextInvalidatesOnlyItsRecognizedChoiceAndSavedDraft() throws {
        let origin = JourneySearchStoreFixtures.place(id: "fr:chosen-paris-nord", name: "Paris Nord", kind: .station)
        let destination = JourneySearchStoreFixtures.place(
            id: "nl:chosen-amsterdam-centraal", name: "Amsterdam Centraal", kind: .station,
            country: "NL", timeZone: "Europe/Amsterdam"
        )
        let store = makeStore(suggestion(), client: ScriptedJourneySearchClient())
        store.selectStation(origin, for: .origin)
        store.selectStation(destination, for: .destination)
        var savedDraft: TicketRouteSuggestion?
        store.onDraftChange = { savedDraft = $0 }

        store.setOrigin("Lyon Part Dieu")
        XCTAssertNil(store.originPlace)
        XCTAssertEqual(store.destinationPlace, destination)
        let originEditedRequest = try XCTUnwrap(store.makeRequest())
        XCTAssertNil(originEditedRequest.originPlace)
        XCTAssertEqual(originEditedRequest.destinationPlace, destination)
        XCTAssertNil(savedDraft?.originPlace)
        XCTAssertEqual(savedDraft?.destinationPlace, destination)

        store.selectStation(origin, for: .origin)
        store.setDestination("Rotterdam Centraal")
        XCTAssertEqual(store.originPlace, origin)
        XCTAssertNil(store.destinationPlace)
        let destinationEditedRequest = try XCTUnwrap(store.makeRequest())
        XCTAssertEqual(destinationEditedRequest.originPlace, origin)
        XCTAssertNil(destinationEditedRequest.destinationPlace)
        let saved = try XCTUnwrap(savedDraft)
        let restored = try JSONDecoder().decode(TicketRouteSuggestion.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.originPlace, origin)
        XCTAssertNil(restored.destinationPlace, "An edited label must not restore its former station ID")
    }

    func testChangingOriginChoiceWithSameNameReinterpretsTicketTimeInNewStationZone() async throws {
        let paris = JourneySearchStoreFixtures.place(id: "fr:central", name: "Central Station", kind: .station)
        let losAngeles = JourneySearchStoreFixtures.place(
            id: "us:central", name: "Central Station", kind: .station,
            country: "US", timeZone: "America/Los_Angeles"
        )
        let destination = JourneySearchStoreFixtures.place(
            id: "nl:amsterdam-centraal", name: "Amsterdam Centraal", kind: .station,
            country: "NL", timeZone: "Europe/Amsterdam"
        )
        let client = ScriptedJourneySearchClient()
        let store = makeStore(suggestion(), client: client)
        store.selectStation(destination, for: .destination)
        store.selectStation(paris, for: .origin)
        let first = try await ImportedJourneyPrefill.resolve(try XCTUnwrap(store.makeRequest()), using: client)
        XCTAssertEqual(first.departureTime, JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"))

        store.selectStation(losAngeles, for: .origin)
        XCTAssertEqual(store.departure, parisClock, "Changing the station preserves the ticket's printed 08:25")
        XCTAssertEqual(store.departureTimeZone?.identifier, "America/Los_Angeles")
        let changedRequest = try XCTUnwrap(store.makeRequest())
        XCTAssertEqual(changedRequest.originPlace?.id, losAngeles.id)
        XCTAssertEqual(store.suggestion.originPlace?.id, losAngeles.id)
        let changed = try await ImportedJourneyPrefill.resolve(changedRequest, using: client)
        XCTAssertEqual(changed.origin?.id, losAngeles.id)
        XCTAssertEqual(changed.departureTime, JourneySearchStoreFixtures.date("2026-07-24T15:25:00Z"))
        let lookups = await client.placeRequests
        XCTAssertTrue(lookups.isEmpty)
    }

    func testChangingCalendarOriginChoicePreservesExplicitEventInstantAndZone() async throws {
        let instant = JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z")
        let imported = TicketRouteSuggestion(
            sourceDescription: "Travel", originGuess: "Paris", destinationGuess: "Amsterdam", trainNumberGuess: "9315",
            departureDate: instant, departureTimeZoneIdentifier: "Europe/Paris",
            calendarSource: CalendarJourneySource(eventKey: "event", revision: "revision")
        )
        let losAngeles = JourneySearchStoreFixtures.place(
            id: "us:los-angeles", name: "Los Angeles Union Station", kind: .station,
            country: "US", timeZone: "America/Los_Angeles"
        )
        let destination = JourneySearchStoreFixtures.place(
            id: "nl:amsterdam-centraal", name: "Amsterdam Centraal", kind: .station,
            country: "NL", timeZone: "Europe/Amsterdam"
        )
        let client = ScriptedJourneySearchClient()
        let store = makeStore(imported, client: client)
        store.selectStation(losAngeles, for: .origin)
        store.selectStation(destination, for: .destination)

        XCTAssertEqual(store.departureTimeZone?.identifier, "Europe/Paris")
        let request = try XCTUnwrap(store.makeRequest())
        XCTAssertEqual(request.calendarSource?.details?.departureDate, instant)
        XCTAssertEqual(request.calendarSource?.details?.timeZoneIdentifier, "Europe/Paris")
        let prefill = try await ImportedJourneyPrefill.resolve(request, using: client)
        XCTAssertEqual(prefill.origin?.id, losAngeles.id)
        XCTAssertEqual(prefill.departureTime, instant, "An explicit Calendar instant must not be shifted into the new station zone")
    }

    func testAliasesResolvingToSameStationExposeDestinationForCorrectionAndRetry() async {
        let boston = JourneySearchStoreFixtures.place(
            id: "us:boston-south", name: "Boston South Station", kind: .station,
            country: "US", timeZone: "America/New_York"
        )
        let newYork = JourneySearchStoreFixtures.place(
            id: "us:new-york-penn", name: "New York Penn Station", kind: .station,
            country: "US", timeZone: "America/New_York"
        )
        let option = JourneySearchStoreFixtures.option(
            id: "corrected", fingerprint: "corrected-route",
            start: JourneySearchStoreFixtures.date("2026-07-24T12:25:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T16:25:00Z"),
            origin: boston, destination: newYork, trainNumber: "2150"
        )
        let client = ScriptedJourneySearchClient(
            places: [.success([boston]), .success([boston]), .success([boston])],
            pages: [.success(JourneySearchStoreFixtures.page(options: [option]))]
        )
        let store = makeStore(suggestion(origin: "BOS", destination: "Boston South Station", number: "2150"), client: client)
        store.start()
        await waitUntil { store.stage == .details(.sameStation) }
        XCTAssertTrue(store.visibleFields.contains(.destination), "The colliding resolved endpoint must remain visibly correctable")
        let invalidRequests = await client.journeyRequests
        XCTAssertTrue(invalidRequests.isEmpty)

        store.selectStation(newYork, for: .destination)
        store.retry()
        await waitUntil { store.search.phase == .reviewing }
        XCTAssertEqual(store.search.selectedOutbound, option)
        let correctedRequests = await client.journeyRequests
        XCTAssertEqual(correctedRequests.count, 1)
        XCTAssertEqual(correctedRequests.first?.originID, boston.id)
        XCTAssertEqual(correctedRequests.first?.destinationID, newYork.id)
        XCTAssertEqual(correctedRequests.first?.requestedTime, JourneySearchStoreFixtures.date("2026-07-24T12:25:00Z"))
    }

    func testCancelledStationPrefillStopsBeforeDestinationLookup() async {
        let origin = JourneySearchStoreFixtures.place(id: "fr:paris-nord", name: "Paris Nord", kind: .station)
        let destination = JourneySearchStoreFixtures.place(
            id: "nl:amsterdam-centraal", name: "Amsterdam Centraal", kind: .station,
            country: "NL", timeZone: "Europe/Amsterdam"
        )
        let client = StalePlaceJourneySearchClient(replacementPlaces: [destination])
        let request = TicketJourneySearchRequest(
            originName: origin.displayName, destinationName: destination.displayName,
            departureTime: parisClock.requestValue, trainNumber: nil, prefersDirectReview: true
        )
        let prefillTask = Task { try await ImportedJourneyPrefill.resolve(request, using: client) }
        await client.waitForFirstRequest()
        prefillTask.cancel()
        await client.resumeFirst(with: [origin])
        do {
            _ = try await prefillTask.value
            XCTFail("A cancelled prefill must not complete")
        } catch is CancellationError {
            // Expected even though the suspended client itself ignores cancellation.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let queries = await client.placeQueries
        XCTAssertEqual(queries, [origin.displayName], "Cancellation prevents the next endpoint request")
    }

    func testClosingBeforeMatchingTaskStartsSendsNoLookup() async {
        let client = ScriptedJourneySearchClient(places: places())
        let store = makeStore(suggestion(), client: client)
        store.start()
        store.cancelMatching()
        // The owned task cannot run until this main-actor call yields.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(store.isPreparingSearch)
        let requests = await client.placeRequests
        XCTAssertTrue(requests.isEmpty, "Closing immediately must cancel even a task that has not started")
    }

    func testReplacementMatchingBeforeTaskStartsPerformsOnlyOnePrefill() async {
        let option = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(places: places(), pages: [.success(JourneySearchStoreFixtures.page(options: [option]))])
        let store = makeStore(suggestion(), client: client)
        store.start()
        store.retry()
        await waitUntil { store.search.phase == .reviewing }
        let requests = await client.placeRequests
        XCTAssertEqual(requests.map(\.query), ["Paris", "Amsterdam"])
        XCTAssertEqual(store.search.selectedOutbound, option)
    }

    private func savedPlan(calendarSource: CalendarJourneySource? = nil) -> TrackedJourneyPlan {
        let departure = JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z")
        let segment = JourneyPlanSegment(
            id: "rail", kind: .rail, from: JourneySearchStoreFixtures.paris, to: JourneySearchStoreFixtures.amsterdam,
            departure: departure, arrival: departure.addingTimeInterval(12_000), serviceName: "Eurostar 9315",
            resolvedTripID: RailIdentifier(rawValue: "trip")
        )
        return TrackedJourneyPlan(
            id: UUID(), createdAt: now, origin: JourneySearchStoreFixtures.paris, destination: JourneySearchStoreFixtures.amsterdam,
            outbound: JourneyPlanDirection(fingerprint: "saved-fingerprint", departure: departure, arrival: departure.addingTimeInterval(12_000),
                                           childTripIDs: [RailIdentifier(rawValue: "trip")], selectedSegments: [segment]),
            returnDirection: nil, preExistingChildTripIDs: [], calendarSource: calendarSource
        )
    }
}
