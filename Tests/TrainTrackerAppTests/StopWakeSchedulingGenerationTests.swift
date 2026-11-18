import Foundation
import TrainTrackerCore
import UserNotifications
import XCTest
@testable import TrainTracker

@MainActor
final class StopWakeSchedulingGenerationTests: XCTestCase {
    @MainActor private final class PendingCenter {
        var requests: [String: UNNotificationRequest] = [:]
        var held: CheckedContinuation<Void, Never>?
        var waitingForHold: CheckedContinuation<Void, Never>?
        var waitingForPair: CheckedContinuation<Void, Never>?
        var holdSuffix: String? = ".approach"

        func add(_ request: UNNotificationRequest) async {
            if let suffix = holdSuffix, request.identifier.hasSuffix(suffix) {
                holdSuffix = nil
                await withCheckedContinuation { continuation in
                    held = continuation
                    waitingForHold?.resume()
                    waitingForHold = nil
                }
            }
            // Model the system completing an older add after the replacement was installed.
            requests[request.identifier] = request
            if requests.count >= 2 {
                waitingForPair?.resume()
                waitingForPair = nil
            }
        }

        func waitUntilHeld() async {
            if held != nil { return }
            await withCheckedContinuation { waitingForHold = $0 }
        }

        func waitForPair() async {
            if requests.count >= 2 { return }
            await withCheckedContinuation { waitingForPair = $0 }
        }

        func completeHeldAdd() {
            held?.resume()
            held = nil
        }
    }

    private func connect(_ alerts: StopWakeAlerts, to center: PendingCenter) {
        alerts.requestPermissions = { (true, false) }
        alerts.addRequest = { await center.add($0) }
        alerts.removeRequests = { ids in ids.forEach { center.requests[$0] = nil } }
        alerts.pendingRequests = { Array(center.requests.values) }
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "StopWakeSchedulingGenerationTests.\(UUID().uuidString)")!
    }

    private func trip(arrival: Date = .now.addingTimeInterval(7_200), confirmedArrival: Bool = false) -> TrainTrip {
        let station: (String, Double) -> Station = { code, latitude in
            Station(id: RailIdentifier(rawValue: "us:amtraker:\(code)"), names: [LocalizedStationName(code)],
                    location: GeoCoordinate(latitude: latitude, longitude: -75), countryCode: "US")
        }
        return TrainTrip(id: RailIdentifier(rawValue: "us:amtraker:wake-test"), source: "amtraker",
            serviceDate: arrival, operatorName: "Amtrak", product: "Test", headsign: "END", stopTimes: [
                StopTime(station: station("START", 40), sequence: 1, scheduledDeparture: arrival.addingTimeInterval(-3_600)),
                StopTime(station: station("END", 41), sequence: 2, scheduledArrival: arrival,
                         arrivalObservedAt: confirmedArrival ? .now.addingTimeInterval(-60) : nil),
            ], capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false,
                hasRealtimeDelays: false, hasAlerts: false, granularity: .perStop))
    }

    func testExplicitTerminalArrivalMakesWakePlanUnavailableWithoutDepartureFlag() {
        let train = trip(confirmedArrival: true)
        XCTAssertFalse(train.stopTimes[1].isPassed)
        XCTAssertNil(StopWakePlan(trip: train, stopID: train.stopTimes[1].station.id.rawValue, leadMinutes: 10))
    }

    func testOlderApproachOrLastCallCompletionCannotOverwriteNewerArm() async throws {
        for suffix in [".approach", ".lastCall"] {
            let alerts = StopWakeAlerts(defaults: defaults())
            let center = PendingCenter()
            center.holdSuffix = suffix
            connect(alerts, to: center)
            let train = trip()
            let stopID = train.stopTimes[1].station.id.rawValue
            let first = Task { await alerts.arm(trip: train, stopID: stopID, productName: "Old", leadMinutes: 5) }
            await center.waitUntilHeld()
            let second = await alerts.arm(trip: train, stopID: stopID, productName: "New", leadMinutes: 15)
            XCTAssertEqual(second, .armed)
            let newerIDs = Set(center.requests.keys)
            XCTAssertEqual(newerIDs.count, 2)
            center.completeHeldAdd()
            let firstResult = await first.value
            XCTAssertEqual(firstResult, .superseded)
            XCTAssertEqual(Set(center.requests.keys), newerIDs)
            XCTAssertTrue(center.requests.values.allSatisfy { $0.content.body.hasPrefix("New") })
            XCTAssertEqual(alerts.alert(for: train.id)?.leadMinutes, 15)
        }
    }

    func testSyncReplacementSurvivesTheOlderSuspendedAdd() async {
        let alerts = StopWakeAlerts(defaults: defaults())
        let center = PendingCenter()
        connect(alerts, to: center)
        let train = trip()
        let first = Task { await alerts.arm(trip: train, stopID: train.stopTimes[1].station.id.rawValue,
                                            productName: "Old", leadMinutes: 10) }
        await center.waitUntilHeld()
        alerts.sync(with: [trip(arrival: train.stopTimes[1].scheduledArrival!.addingTimeInterval(600))])
        await center.waitForPair()
        let newerIDs = Set(center.requests.keys)
        center.completeHeldAdd()
        _ = await first.value
        XCTAssertEqual(Set(center.requests.keys), newerIDs)
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertTrue(center.requests.values.allSatisfy { $0.content.body.hasPrefix("Test") })
    }

    func testDisarmThenRearmDoesNotLetOldCleanupRemoveNewRequests() async {
        let alerts = StopWakeAlerts(defaults: defaults())
        let center = PendingCenter()
        connect(alerts, to: center)
        let train = trip()
        let first = Task { await alerts.arm(trip: train, stopID: train.stopTimes[1].station.id.rawValue,
                                            productName: "Old", leadMinutes: 10) }
        await center.waitUntilHeld()
        alerts.disarm(tripID: train.id)
        _ = await alerts.arm(trip: train, stopID: train.stopTimes[1].station.id.rawValue, productName: "New", leadMinutes: 15)
        let newerIDs = Set(center.requests.keys)
        center.completeHeldAdd()
        _ = await first.value
        await alerts.reconcilePendingRequests()
        XCTAssertEqual(Set(center.requests.keys), newerIDs)
        XCTAssertEqual(center.requests.count, 2)
    }

    func testRestorationKeepsOwnedRequestsAndRemovesOrphanGenerations() async {
        let saved = defaults()
        let alerts = StopWakeAlerts(defaults: saved)
        let center = PendingCenter()
        center.holdSuffix = nil
        connect(alerts, to: center)
        let train = trip()
        _ = await alerts.arm(trip: train, stopID: train.stopTimes[1].station.id.rawValue, productName: "New", leadMinutes: 10)
        let ownedIDs = Set(center.requests.keys)
        let orphan = UNNotificationRequest(identifier: "wake.\(train.id.rawValue).orphan.approach",
            content: UNMutableNotificationContent(), trigger: nil)
        center.requests[orphan.identifier] = orphan
        let restored = StopWakeAlerts(defaults: saved)
        connect(restored, to: center)
        await restored.reconcilePendingRequests()
        XCTAssertEqual(restored.alert(for: train.id)?.requestGeneration, alerts.alert(for: train.id)?.requestGeneration)
        XCTAssertEqual(Set(center.requests.keys), ownedIDs)
        restored.disarm(tripID: train.id)
        await restored.reconcilePendingRequests()
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testLegacyStoredIdentifiersRemainOwnedUntilReplaced() async throws {
        let saved = defaults()
        let train = trip()
        let legacy = StopWakeAlerts.Alert(tripID: train.id.rawValue, stopID: train.stopTimes[1].station.id.rawValue,
            stopName: "END", leadMinutes: 10, usesLocation: false, scheduledArrival: train.stopTimes[1].scheduledArrival!)
        saved.set(try JSONEncoder().encode([train.id.rawValue: legacy]), forKey: "stopWakeAlerts")
        let alerts = StopWakeAlerts(defaults: saved)
        let center = PendingCenter()
        center.holdSuffix = nil
        for suffix in ["approach", "lastCall"] {
            let request = UNNotificationRequest(identifier: "wake.\(train.id.rawValue).\(suffix)",
                content: UNMutableNotificationContent(), trigger: nil)
            center.requests[request.identifier] = request
        }
        connect(alerts, to: center)
        await alerts.reconcilePendingRequests()
        let legacyIDs = Set(center.requests.keys)
        XCTAssertEqual(legacyIDs.count, 2)
        _ = await alerts.arm(trip: train, stopID: legacy.stopID, productName: "New", leadMinutes: 15)
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertTrue(legacyIDs.isDisjoint(with: center.requests.keys))
    }
}
