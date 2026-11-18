import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class FeaturedTrainDiscoveryTests: XCTestCase {
    func testFailedSearchCanRetryAndUseTheSecondHub() async throws {
        let finder = FirstRunTrainFinder(regionCode: "US")
        await finder.discover { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(finder.state, .unavailable)
        finder.retry()
        XCTAssertEqual(finder.lookupRevision, 1)
        XCTAssertEqual(finder.state, .looking)

        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: .now).first)
        var visited: [FirstRunHub] = []
        await finder.discover(timeout: .seconds(1), fallbackAfter: .seconds(30)) { hub in
            visited.append(hub)
            if hub == finder.hubs.first { throw URLError(.networkConnectionLost) }
            return trip
        }
        XCTAssertEqual(visited, finder.hubs)
        XCTAssertEqual(finder.featured?.trip.id, trip.id)
    }

    func testSlowFirstHubLeavesTimeForAHealthyFallback() async throws {
        let finder = FirstRunTrainFinder(regionCode: "US")
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: .now).first)
        var visited: [FirstRunHub] = []
        await finder.discover(timeout: .seconds(1), fallbackAfter: .milliseconds(10)) { hub in
            visited.append(hub)
            if hub == finder.hubs.first {
                try await Task.sleep(for: .seconds(30))
                return nil
            }
            return trip
        }
        XCTAssertEqual(visited, finder.hubs)
        XCTAssertEqual(finder.featured?.trip.id, trip.id)
    }

    func testEmptyFallbackDoesNotHideASlowerPrimaryTrain() async throws {
        let finder = FirstRunTrainFinder(regionCode: "US")
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: .now).first)
        let fallbackStarted = AsyncStream<Void>.makeStream()
        await finder.discover(timeout: .seconds(1), fallbackAfter: .milliseconds(5)) { hub in
            if hub == finder.hubs.first {
                for await _ in fallbackStarted.stream { break }
                return trip
            }
            fallbackStarted.continuation.yield(())
            fallbackStarted.continuation.finish()
            return nil
        }
        XCTAssertEqual(finder.featured?.trip.id, trip.id)
    }

    func testAnEmptyBoardDoesNotAdvertiseAProviderFailureOrRefetchImmediately() async {
        let finder = FirstRunTrainFinder(regionCode: "US")
        var lookups = 0
        await finder.discover { _ in lookups += 1; return nil }
        XCTAssertEqual(finder.state, .none)
        finder.retry()
        await finder.discover { _ in lookups += 1; return nil }
        XCTAssertEqual(lookups, finder.hubs.count)
        XCTAssertEqual(finder.lookupRevision, 0)
    }

    func testTimedOutLookupIsRetryable() async {
        let finder = FirstRunTrainFinder()
        await finder.discover(timeout: .milliseconds(15)) { _ in
            try await Task.sleep(for: .seconds(30))
            return nil
        }
        XCTAssertEqual(finder.state, .unavailable)
        finder.retry()
        XCTAssertEqual(finder.state, .looking)
    }

    func testCancellationLeavesTheNextVisitFreeToDiscover() async throws {
        let finder = FirstRunTrainFinder()
        let started = expectation(description: "The station lookup started")
        let first = Task {
            await finder.discover { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return nil
            }
        }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        await first.value
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: .now).first)
        await finder.discover { _ in trip }
        XCTAssertEqual(finder.featured?.trip.id, trip.id)
    }

    func testSuggestedTrainOnlyClaimsToBeRunningWithCurrentEvidence() throws {
        let date = Date.now
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: date).first)
        var featured = FirstRunTrainFinder.Featured(trip: trip, checkedAt: date)
        XCTAssertEqual(featured.title(at: date), "Running right now")
        XCTAssertEqual(featured.title(at: date.addingTimeInterval(20 * 60)), "Featured train")
        featured.refreshFailed = true
        XCTAssertEqual(featured.trust(at: date), .saved)
        XCTAssertEqual(featured.title(at: date), "Featured train")
    }

    func testReturnAfterArrivalRemovesTheOldFollowActionAndSearchesAgain() async throws {
        let finder = FirstRunTrainFinder(regionCode: "US")
        let date = Date.now
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: date).first)
        await finder.discover { _ in trip }
        let source = ResumeSource(trip: trip)
        await finder.load(library: library(using: source), at: date.addingTimeInterval(24 * 3600))
        XCTAssertNil(finder.featured)
        XCTAssertEqual(finder.state, .none)
        let searched = await source.stationSearches
        XCTAssertEqual(searched, finder.hubs.map(\.query))
    }

    func testReturnToAnUnderwayTrainRechecksOnlyWhenItsSnapshotIsStale() async throws {
        let date = Date.now
        let resumed = date.addingTimeInterval(JourneyTrust.liveWindow + 60)
        let trip = try XCTUnwrap(PreviewTrips.make(referenceDate: date).first)
        let newer = try XCTUnwrap(PreviewTrips.make(referenceDate: resumed).first)
        let finder = FirstRunTrainFinder(regionCode: "US")
        await finder.discover { _ in trip }
        let source = ResumeSource(trip: newer)
        let library = library(using: source)
        await finder.load(library: library, at: date.addingTimeInterval(30))
        let firstCount = await source.refreshCount
        XCTAssertEqual(firstCount, 0)
        await finder.load(library: library, at: resumed)
        XCTAssertEqual(finder.featured?.trip, newer)
        XCTAssertEqual(finder.featured?.checkedAt, resumed)
        let secondCount = await source.refreshCount
        let searched = await source.stationSearches
        XCTAssertEqual(secondCount, 1)
        XCTAssertTrue(searched.isEmpty)
    }

    private func library(using source: ResumeSource) -> TripLibrary {
        TripLibrary(trips: [], backendSnapshots: source, pushCoordinator: RecordingPushCoordinator(),
                    archive: nil, automaticRefreshEnabled: false)
    }
}

private actor ResumeSource: TripDataProviding {
    let trip: TrainTrip
    private(set) var refreshCount = 0
    private(set) var stationSearches: [String] = []
    init(trip: TrainTrip) { self.trip = trip }

    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip {
        refreshCount += 1
        return self.trip
    }

    func searchStations(query: String, source: RailSource) async throws -> [Station] {
        stationSearches.append(query)
        return []
    }

    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection,
               source: RailSource?) async throws -> [StopTimeSummary] { [] }

    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip { trip }
}
