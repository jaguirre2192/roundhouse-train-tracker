import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class JourneyRouteOutlineTests: XCTestCase {
    func testGapsCountActualCallsAndKeepTheFocusBetweenThem() {
        let calls = [10, 20, 30, 40, 50, 60, 70].map(stop)
        let route = JourneyRouteOutline(stops: calls, focusID: calls[3].id)
        XCTAssertEqual(route.visibleStops.map(\.sequence), [10, 40, 70])
        XCTAssertEqual(gaps(in: route).map(\.count), [2, 2])
        XCTAssertEqual(gaps(in: route).map { [$0.from.sequence, $0.to.sequence] }, [[10, 40], [40, 70]])
        XCTAssertEqual(route.gapCount, 2)
        XCTAssertFalse(route.canCollapse)
        XCTAssertEqual(Set(route.rows.map(\.id)).count, route.rows.count)
    }

    func testOpeningAStretchRevealsOnlyItsCallsThenOpeningLastStretchRevealsAll() throws {
        let calls = (1...7).map(stop)
        let summary = JourneyRouteOutline(stops: calls, focusID: calls[3].id)
        let first = try XCTUnwrap(gaps(in: summary).first)
        let partiallyOpen = JourneyRouteOutline.Expansion.compact.opening(first, remainingGaps: summary.gapCount)
        let partial = JourneyRouteOutline(stops: calls, focusID: calls[3].id, expansion: partiallyOpen)
        XCTAssertEqual(partial.visibleStops.map(\.sequence), [1, 2, 3, 4, 7])
        XCTAssertEqual(gaps(in: partial).map(\.count), [2])
        XCTAssertTrue(partial.canCollapse)

        let final = try XCTUnwrap(gaps(in: partial).first)
        let open = partiallyOpen.opening(final, remainingGaps: partial.gapCount)
        XCTAssertEqual(open, .all)
        let all = JourneyRouteOutline(stops: calls + [stop(8)], focusID: calls[3].id, expansion: open)
        XCTAssertEqual(all.visibleStops.map(\.sequence), Array(1...8))
        XCTAssertEqual(all.gapCount, 0)
        XCTAssertTrue(all.canCollapse)
        let folded = JourneyRouteOutline(stops: calls, focusID: calls[3].id, expansion: .compact)
        XCTAssertEqual(folded.rows.map(\.id), summary.rows.map(\.id))
    }

    func testOpenStretchSurvivesInsertedCallsAndAChangingNextStop() throws {
        let calls = [10, 20, 30, 40, 50].map(stop)
        let summary = JourneyRouteOutline(stops: calls, focusID: calls[2].id)
        let first = try XCTUnwrap(gaps(in: summary).first)
        let opened = JourneyRouteOutline.Expansion.compact.opening(first, remainingGaps: summary.gapCount)
        let refreshed = [10, 15, 20, 30, 35, 40, 45, 50].map(stop)
        let moved = JourneyRouteOutline(stops: refreshed, focusID: stop(40).id, expansion: opened)
        XCTAssertEqual(moved.visibleStops.map(\.sequence), [10, 15, 20, 30, 40, 50])
        XCTAssertEqual(gaps(in: moved).map(\.count), [1, 1])

        let shortened = refreshed.filter { $0.sequence >= 20 }
        let segment = JourneyRouteOutline(stops: shortened, focusID: stop(40).id, expansion: opened)
        XCTAssertEqual(segment.visibleStops.map(\.sequence), [20, 40, 50])
        XCTAssertEqual(gaps(in: segment).map(\.count), [2, 1])
        XCTAssertFalse(segment.canCollapse)
    }

    func testShortRoutesStayCompleteAndTerminalFocusProducesOnlyOneGap() {
        for length in 0...3 {
            let calls = (0..<length).map(stop)
            let route = JourneyRouteOutline(stops: calls, focusID: nil)
            XCTAssertEqual(route.visibleStops, calls)
            XCTAssertEqual(route.gapCount, 0)
            XCTAssertFalse(route.canCollapse)
        }
        let calls = (1...5).map(stop)
        for focusID in [nil, calls.first?.id, calls.last?.id, "absent"] {
            let route = JourneyRouteOutline(stops: calls, focusID: focusID)
            XCTAssertEqual(route.visibleStops.map(\.sequence), [1, 5])
            XCTAssertEqual(gaps(in: route).map(\.count), [3])
        }
    }

    private func gaps(in outline: JourneyRouteOutline) -> [JourneyRouteOutline.Gap] {
        outline.rows.compactMap {
            guard case .gap(let gap) = $0 else { return nil }
            return gap
        }
    }

    // Loop services can call at the same station repeatedly. Sequence identifies the call.
    private func stop(_ sequence: Int) -> StopTime {
        let station = Station(id: RailIdentifier(region: "us", source: "test", nativeID: "loop"),
                              names: [LocalizedStationName("Union Station", localeIdentifier: "en")],
                              location: GeoCoordinate(latitude: 38.9, longitude: -77), countryCode: "US")
        return StopTime(station: station, sequence: sequence)
    }
}
