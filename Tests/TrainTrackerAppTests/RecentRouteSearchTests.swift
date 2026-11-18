import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class RecentRouteSearchTests: XCTestCase {
    private let paris = JourneySearchStoreFixtures.paris
    private let amsterdam = JourneySearchStoreFixtures.amsterdam

    func testOnlyCompleteSubmissionsMakeRoutesAndReverseHasItsOwnIdentity() {
        let history = RailPlaceRecents(defaults: nil)
        history.record(paris)
        history.record(amsterdam)
        history.recordSearch(JourneySearchFormState(origin: paris))
        history.recordSearch(JourneySearchFormState(origin: paris, destination: paris))
        XCTAssertTrue(history.routes.isEmpty)

        history.recordSearch(JourneySearchFormState(origin: paris, destination: amsterdam))
        history.recordSearch(JourneySearchFormState(origin: amsterdam, destination: paris))
        let renamedParis = JourneySearchStoreFixtures.place(id: paris.id.rawValue, name: "Paris (all stations)")
        history.recordSearch(JourneySearchFormState(origin: renamedParis, destination: amsterdam))
        XCTAssertEqual(history.routes, [
            RecentRailRoute(origin: renamedParis, destination: amsterdam),
            RecentRailRoute(origin: amsterdam, destination: paris),
        ])
        XCTAssertEqual(history.choices(for: JourneySearchFormState())?.suggested, history.routes[0])
        XCTAssertEqual(history.choices(for: JourneySearchFormState(origin: paris))?.suggested, history.routes[0])
        let selectedDestination = history.choices(for: JourneySearchFormState(destination: paris))
        XCTAssertEqual(selectedDestination?.suggested, history.routes[1])
        XCTAssertEqual(selectedDestination?.alternatives, [history.routes[0]])
        XCTAssertNil(history.choices(for: JourneySearchFormState(origin: paris, destination: amsterdam)))
    }

    func testHomeStationAllowsChoosingARecentTripAwayFromHomeWithoutChangingTravelOptions() throws {
        let away = RecentRailRoute(origin: paris, destination: amsterdam)
        let history = RailPlaceRecents(defaults: nil)
        history.recordSearch(JourneySearchFormState(origin: away.origin, destination: away.destination))
        var form = JourneySearchStoreFixtures.form()
        form.origin = JourneySearchStoreFixtures.place(id: "fixture:station:lyon", name: "Lyon")
        form.destination = nil
        form.outboundArriveBy = true
        form.returnArriveBy = true
        form.directOnly = true
        form.maximumTransfers = 0
        let store = makeJourneySearchStore(client: ScriptedJourneySearchClient(), form: form)
        let choices = try XCTUnwrap(history.choices(for: store.form))
        XCTAssertNil(choices.suggested)
        XCTAssertEqual(choices.alternatives, [away])
        let selected = try XCTUnwrap(choices.alternatives.first)
        store.setPlaces(origin: selected.origin, destination: selected.destination)
        form.origin = away.origin
        form.destination = away.destination
        XCTAssertEqual(store.form, form)
        XCTAssertNil(history.choices(for: store.form))
    }

    func testHistoryPersistsWithABoundAndCanBeRemovedIndependentlyOfPlaces() throws {
        let suite = "RecentRouteSearchTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = RailPlaceRecents(defaults: defaults)
        history.record(paris)
        for number in 0..<8 {
            let station = JourneySearchStoreFixtures.place(id: "fixture:\(number)", name: "Station \(number)")
            history.recordSearch(JourneySearchFormState(origin: paris, destination: station))
        }
        let reloaded = RailPlaceRecents(defaults: defaults)
        XCTAssertEqual(reloaded.routes.map(\.destination.displayName), (2..<8).reversed().map { "Station \($0)" })
        XCTAssertEqual(reloaded.count, 7)
        XCTAssertTrue(RailPlaceRecents(defaults: nil).routes.isEmpty)
        let oldest = try XCTUnwrap(reloaded.routes.last)
        reloaded.remove(oldest)
        XCTAssertEqual(RailPlaceRecents(defaults: defaults).routes.count, 5)
        reloaded.clearPlaces()
        XCTAssertEqual(reloaded.count, 5)
        reloaded.record(paris)
        reloaded.clearRoutes()
        XCTAssertEqual(RailPlaceRecents(defaults: defaults).places, [paris])
        XCTAssertTrue(RailPlaceRecents(defaults: defaults).routes.isEmpty)
        reloaded.recordSearch(JourneySearchStoreFixtures.form())
        reloaded.clear()
        XCTAssertEqual(RailPlaceRecents(defaults: defaults).count, 0)
    }

    func testChangingBothStationsKeepsTimingsAndFiltersAndRejectsSupersededResults() async {
        let replacement = JourneySearchStoreFixtures.page(options: [journeyReturnOption()])
        let old = JourneySearchStoreFixtures.page(options: [journeyOutboundOption()])
        let client = StaleJourneySearchClient(replacementPage: replacement)
        var form = JourneySearchStoreFixtures.form()
        form.outboundArriveBy = true
        form.returnArriveBy = true
        form.directOnly = true
        form.maximumTransfers = 0
        let store = makeJourneySearchStore(client: client, form: form)
        store.searchOutbound()
        await client.waitForFirstRequest()

        store.setPlaces(origin: amsterdam, destination: paris)
        form.swapPlaces()
        XCTAssertEqual(store.form, form)
        assertJourneySelectionsCleared(store)
        XCTAssertFalse(store.isJourneyTaskActive)
        let requestsBeforeSubmit = await client.journeyRequests
        XCTAssertEqual(requestsBeforeSubmit.count, 1)

        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        await client.resumeFirst(with: old)
        await Task.yield()
        XCTAssertEqual(store.outboundPage, replacement)
        let requests = await client.journeyRequests
        XCTAssertEqual(requests.last?.originID, amsterdam.id)
        XCTAssertEqual(requests.last?.destinationID, paris.id)
        XCTAssertEqual(requests.last?.requestedTime, form.outboundTime)
    }
}
