import AppIntents
import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class TrainJourneyIntentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_804_000)

    func testIdentifierLookupKeepsSavedPastTrainsButRejectsMissingAndDuplicateIDs() {
        let past = makeTrip(id: "past", departure: -7_200, arrival: -3_600)
        let future = makeTrip(id: "future", departure: 3_600, arrival: 7_200)
        let catalog = SavedTrainEntityCatalog(trips: [past, future], referenceDate: now)

        XCTAssertEqual(
            catalog.entities(for: [future.id.rawValue, "removed", past.id.rawValue, future.id.rawValue]).map(\.id),
            [future.id.rawValue, past.id.rawValue]
        )
    }

    func testSpotlightUpdateIndexesCurrentEntitiesAndDeletesOnlyRemovedIdentifiers() {
        let past = makeTrip(id: "past", departure: -7_200, arrival: -3_600)
        let future = makeTrip(id: "future", departure: 3_600, arrival: 7_200)
        let entities = SavedTrainEntityCatalog(trips: [past, future], referenceDate: now).allEntities()

        let update = SavedTrainSpotlightUpdate(
            entities: entities,
            previouslyIndexedIdentifiers: [past.id.rawValue, "removed", "removed"]
        )

        XCTAssertEqual(update.entities.map(\.id), [past.id.rawValue, future.id.rawValue])
        XCTAssertEqual(update.removedIdentifiers, ["removed"])
    }

    func testSuggestionsUseCurrentJourneyWindowInsteadOfProviderPassedFlags() {
        let past = makeTrip(id: "past", departure: -7_200, arrival: -3_600)
        let underway = makeTrip(id: "underway", departure: -1_800, arrival: 1_800, allPassed: true)
        let future = makeTrip(id: "future", departure: 3_600, arrival: 7_200)
        let catalog = SavedTrainEntityCatalog(trips: [future, past, underway], referenceDate: now)

        XCTAssertEqual(catalog.suggestedEntities().map(\.id), [underway.id.rawValue, future.id.rawValue])
    }

    func testDelayedArrivalKeepsTrainSuggestedAfterItsScheduledArrival() {
        let delayed = makeTrip(id: "delayed", departure: -3_600, arrival: -600, expectedArrival: 1_200)
        let catalog = SavedTrainEntityCatalog(trips: [delayed], referenceDate: now)

        XCTAssertEqual(catalog.suggestedEntities().map(\.id), [delayed.id.rawValue])
    }

    func testSuggestionsRejectInvalidTimetableAndEndedBoundary() {
        let invalid = makeTrip(id: "invalid", departure: 7_200, arrival: 3_600)
        let justEnded = makeTrip(id: "ended", departure: -3_600, arrival: 0)
        let catalog = SavedTrainEntityCatalog(trips: [invalid, justEnded], referenceDate: now)

        XCTAssertTrue(catalog.suggestedEntities().isEmpty)
        XCTAssertEqual(catalog.entities(for: [invalid.id.rawValue, justEnded.id.rawValue]).count, 2)
    }

    func testSearchMatchesDisplayFieldsWithoutDiacriticsAndRequiresEveryTerm() {
        let trip = makeTrip(id: "search", departure: 600, arrival: 3_600)
        let catalog = SavedTrainEntityCatalog(trips: [trip], referenceDate: now)

        XCTAssertEqual(catalog.entities(matching: "munchen ice").map(\.id), [trip.id.rawValue])
        XCTAssertTrue(catalog.entities(matching: "ICE London").isEmpty)
        XCTAssertTrue(catalog.entities(matching: "provider-only-headsign").isEmpty)
    }

    func testSelectedLegSuppliesDisplayEndpointsAndItsOwnSuggestionWindow() throws {
        let trip = makeTrip(id: "selected", departure: -3_600, arrival: 3_600)
        let plan = makePlan(trip: trip, alightingIndex: 1)
        let catalog = SavedTrainEntityCatalog(trips: [trip], plans: [plan], referenceDate: now)
        let entity = try XCTUnwrap(catalog.entities(for: [trip.id.rawValue]).first)

        XCTAssertEqual(entity.originName, "München Hbf")
        XCTAssertEqual(entity.destinationName, "Nürnberg Hbf")
        XCTAssertEqual(entity.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertTrue(catalog.suggestedEntities().isEmpty)
        XCTAssertEqual(SavedTrainEntityCatalog(trips: [trip], referenceDate: now).suggestedEntities().count, 1)
    }

    func testProviderIndependentSelectedLegRemainsAvailableToShortcuts() throws {
        let trip = makeTrip(id: "provider-independent", departure: -600, arrival: 3_600)
        let plan = makePlan(trip: trip, alightingIndex: 1, usesOpaquePlaceIDs: true)
        let catalog = SavedTrainEntityCatalog(trips: [trip], plans: [plan], referenceDate: now)
        let entity = try XCTUnwrap(catalog.suggestedEntities().first)

        XCTAssertEqual(entity.id, trip.id.rawValue)
        XCTAssertEqual(entity.originName, "München Hbf")
        XCTAssertEqual(entity.destinationName, "Nürnberg Hbf")
    }

    func testUnknownStationTimeZoneIsExplicitlyUTC() throws {
        let trip = makeTrip(id: "unknown-zone", departure: 600, arrival: 3_600)
        let entity = try XCTUnwrap(
            SavedTrainEntityCatalog(trips: [trip], referenceDate: now).entities(for: [trip.id.rawValue]).first
        )

        XCTAssertNil(entity.timeZoneIdentifier)
        XCTAssertTrue(entity.departureDescription.hasSuffix("UTC"))
    }

    func testInvalidDepartureDateRemainsResolvableWithoutInventingADate() throws {
        let trip = makeTrip(id: "invalid-date", departure: .nan, arrival: 3_600)
        let catalog = SavedTrainEntityCatalog(trips: [trip], referenceDate: now)
        let entity = try XCTUnwrap(catalog.entities(for: [trip.id.rawValue]).first)

        XCTAssertEqual(entity.departureDescription, "Date unavailable")
        XCTAssertTrue(catalog.suggestedEntities().isEmpty)
    }

    @MainActor
    func testQueryRechecksTheLibraryAfterAResolvedTrainIsRemoved() async throws {
        let trip = makeTrip(id: "removed", departure: 600, arrival: 3_600)
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trip])
        defer { context.cleanup() }
        let referenceDate = now
        let query = SavedTrainQuery {
            SavedTrainEntityCatalog(trips: context.library.trips, referenceDate: referenceDate)
        }
        let before = try await query.entities(for: [trip.id.rawValue])
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(context.library.removeTrip(id: trip.id))

        let after = try await query.entities(for: [trip.id.rawValue])
        let suggestions = try await query.suggestedEntities()
        let search = try await query.entities(matching: "ICE")
        XCTAssertTrue(after.isEmpty)
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(search.isEmpty)
    }

    @MainActor
    func testRuntimeRoutesTheSavedIDUsingItsExistingLibraryAndNavigation() throws {
        let trip = makeTrip(id: "route", departure: 600, arrival: 3_600)
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trip])
        defer { context.cleanup() }
        let navigation = AppNavigationModel()
        let runtime = TrainJourneyRuntime(library: context.library, navigation: navigation)

        try runtime.openSavedTrain(id: trip.id.rawValue)

        XCTAssertTrue(runtime.library === context.library)
        XCTAssertTrue(runtime.navigation === navigation)
        XCTAssertNil(runtime.planLibrary)
        XCTAssertEqual(navigation.requestedJourney?.tripID, trip.id)
        XCTAssertEqual(navigation.requestedSection, .trips)
    }

    @MainActor
    func testRuntimeRejectsRemovedTrainBeforeChangingNavigation() throws {
        let trip = makeTrip(id: "removed-route", departure: 600, arrival: 3_600)
        let context = try JourneyPlanTestFixtures.makeTripLibrary(trips: [trip])
        defer { context.cleanup() }
        let navigation = AppNavigationModel()
        let runtime = TrainJourneyRuntime(library: context.library, navigation: navigation)
        XCTAssertTrue(context.library.removeTrip(id: trip.id))

        XCTAssertThrowsError(try runtime.openSavedTrain(id: trip.id.rawValue)) { error in
            XCTAssertTrue(error is SavedTrainIntentError)
        }
        XCTAssertNil(navigation.requestedJourney)
        XCTAssertNil(navigation.requestedSection)
    }

    @MainActor
    func testStationSearchRequestTrimsTheQueryAndRoutesToTheSearchSection() {
        let navigation = AppNavigationModel()

        navigation.openStationSearch(query: "  Berlin Hauptbahnhof  ")

        XCTAssertEqual(navigation.requestedStationSearch?.query, "Berlin Hauptbahnhof")
        XCTAssertEqual(navigation.requestedSection, .stations)
        navigation.dismissStationSearch()
        XCTAssertNil(navigation.requestedStationSearch)
    }

    private func makeTrip(
        id: String, departure: TimeInterval, arrival: TimeInterval,
        expectedArrival: TimeInterval? = nil, allPassed: Bool = false
    ) -> TrainTrip {
        let names = ["München Hbf", "Nürnberg Hbf", "Berlin Hbf"]
        let times = [departure, (departure + arrival) / 2, arrival]
        let stops = names.enumerated().map { index, name in
            StopTime(
                station: Station(
                    id: RailIdentifier(rawValue: "test:station:\(index)"),
                    names: [LocalizedStationName(name)],
                    location: GeoCoordinate(latitude: 48 + Double(index), longitude: 11),
                    countryCode: "DE"
                ),
                sequence: index,
                scheduledArrival: index == 0 ? nil : now.addingTimeInterval(times[index]),
                scheduledDeparture: index == 2 ? nil : now.addingTimeInterval(times[index]),
                expectedArrival: index == 2 ? expectedArrival.map(now.addingTimeInterval) : nil,
                isPassed: allPassed
            )
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "test:trip:\(id)"), source: "test", serviceDate: now,
            operatorName: "Test Rail", product: "ICE 100", headsign: "provider-only-headsign",
            stopTimes: stops,
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: false, hasRealtimeDelays: false,
                hasAlerts: false, granularity: .perStop
            )
        )
    }

    private func makePlan(
        trip: TrainTrip,
        alightingIndex: Int,
        usesOpaquePlaceIDs: Bool = false
    ) -> TrackedJourneyPlan {
        let places = trip.stopTimes.enumerated().map { index, stop in
            let payload = Data("search-\(index)\u{1f}DE\u{1f}\u{1f}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return RailPlace(
                id: usesOpaquePlaceIDs
                    ? RailIdentifier(rawValue: "rail:transitous:station:\(payload)")
                    : stop.station.id,
                kind: .station, displayName: stop.station.displayName,
                context: "", countryCode: "DE", timeZoneIdentifier: "Europe/Berlin",
                location: stop.station.location, eligibleModes: ["rail"], attributions: []
            )
        }
        let departure = trip.stopTimes[0].scheduledDeparture ?? now
        let arrival = trip.stopTimes[alightingIndex].scheduledArrival ?? now
        let segment = JourneyPlanSegment(
            id: "selected-leg", kind: .rail, from: places[0], to: places[alightingIndex],
            departure: departure, arrival: arrival, serviceName: trip.product, resolvedTripID: trip.id
        )
        return TrackedJourneyPlan(
            id: UUID(), createdAt: now, origin: places[0], destination: places[alightingIndex],
            outbound: JourneyPlanDirection(
                fingerprint: "selected", departure: departure, arrival: arrival,
                childTripIDs: [trip.id], selectedSegments: [segment]
            ),
            returnDirection: nil, preExistingChildTripIDs: []
        )
    }
}
