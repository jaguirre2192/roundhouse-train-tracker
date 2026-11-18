import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class HudsonWindowGuideTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_010_200)

    @MainActor func testLiveEmpireServiceBoardOpensItsGuide() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_TRAIN_TRACKER_TESTS"] == "1" else {
            throw XCTSkip("Opt in to the published rail feed.")
        }
        let client = TripSnapshotBackendClient()
        let now = Date.now
        let calls = try await client.board(stationID: .init(rawValue: "us:amtraker:ALB"), at: now,
                                           direction: .departures, source: .unitedStates)
        guard let departure = calls.first(where: { $0.product.localizedCaseInsensitiveContains("Empire Service") }) else {
            throw XCTSkip("No Empire Service departure is currently on the Albany board.")
        }
        let train = try await client.trip(id: departure.tripID, serviceDate: departure.serviceDate, source: .unitedStates)
        XCTAssertEqual(train.id, departure.tripID)
        XCTAssertTrue(HudsonWindowGuide.matches(train), train.product)
        let selected = HudsonWindowGuide.nearbyLandmark(on: train, at: .now)
        let record = XCTAttachment(string: "\(train.product), \(train.stopTimes.count) calls, \(train.positions.count) train positions, guide scene: \(selected?.name ?? "manual").")
        record.name = "Published Empire Service in Window Seat"
        record.lifetime = .keepAlways
        add(record)
    }

    func testMatchingRequiresServiceAndTwoDistinctCorridorStations() {
        let train = HudsonWindowQA.trip(at: now)
        XCTAssertTrue(HudsonWindowGuide.matches(train))
        XCTAssertFalse(HudsonWindowGuide.matches(train, stops: [train.stopTimes[0], train.stopTimes[0]]))
        XCTAssertFalse(HudsonWindowGuide.matches(HudsonWindowQA.trip(at: now, product: "Maple Leaf 63")))
        XCTAssertEqual(HudsonWindowGuide.firstLandmark(for: train), .manhattan)
        XCTAssertEqual(HudsonWindowGuide.firstLandmark(for: HudsonWindowQA.trip(at: now, reversed: true)), .albany)
    }

    func testManualGuideOpensAtThePassengersBoardingStation() throws {
        let train = HudsonWindowQA.trip(at: now)
        let intermediate = try XCTUnwrap(train.stopTimes.firstIndex { AmtrakPositionMatcher.amtrakCode(for: $0.station) == "POU" })
        XCTAssertEqual(HudsonWindowGuide.firstLandmark(for: train, stops: Array(train.stopTimes[intermediate...])), .bridge)
        XCTAssertNil(HudsonWindowGuide.nearbyLandmark(on: train, at: now))
    }

    func testFreshMatchedTrainPositionOrDatedCallCanSelectLandmark() {
        let fix = HudsonWindowQA.position(near: .highlands, at: now)
        XCTAssertEqual(HudsonWindowGuide.nearbyLandmark(on: HudsonWindowQA.trip(at: now, positions: [fix]), at: now), .highlands)
        let call = HudsonWindowQA.trip(at: now, bridgeReport: now.addingTimeInterval(-30))
        XCTAssertEqual(HudsonWindowGuide.nearbyLandmark(on: call, at: now), .bridge)
    }

    func testDraggingToTheEndsOfAWideWindowSelectsTheOuterLandmarks() {
        XCTAssertEqual(WindowSeatFraming.landmark(at: 0, printWidth: 1_320, windowWidth: 669), .manhattan)
        XCTAssertEqual(WindowSeatFraming.landmark(at: 651, printWidth: 1_320, windowWidth: 669), .albany)
        for scene in [HudsonLandmark.highlands, .bridge] {
            let offset = WindowSeatFraming.offset(for: scene, printWidth: 1_320, windowWidth: 669)
            XCTAssertEqual(WindowSeatFraming.landmark(at: offset, printWidth: 1_320, windowWidth: 669), scene)
        }
    }

    func testTimetableStaleEstimatedAndFutureReportsKeepGuideManual() {
        let invalid = [HudsonWindowQA.position(near: .bridge, at: now.addingTimeInterval(-301)),
                       HudsonWindowQA.position(near: .bridge, at: now, source: .inferred),
                       HudsonWindowQA.position(near: .bridge, at: now.addingTimeInterval(360))]
        for fix in invalid {
            XCTAssertNil(HudsonWindowGuide.nearbyLandmark(on: HudsonWindowQA.trip(at: now, positions: [fix]), at: now))
        }
        XCTAssertNil(HudsonWindowGuide.nearbyLandmark(on: HudsonWindowQA.trip(at: now, passedWithoutReport: true), at: now))
        XCTAssertNil(HudsonWindowGuide.nearbyLandmark(on: HudsonWindowQA.trip(at: now, bridgeReport: now.addingTimeInterval(-301)), at: now))
    }

    func testCurrentPositionAwayFromAnyLandmarkOverridesRecentStationReport() {
        let fix = VehiclePosition(coordinate: .init(latitude: 42.26, longitude: -73.80), source: .real, confidence: 1, asOf: now)
        let train = HudsonWindowQA.trip(at: now, positions: [fix], bridgeReport: now.addingTimeInterval(-200))
        XCTAssertNil(HudsonWindowGuide.nearbyLandmark(on: train, at: now))
    }
}
