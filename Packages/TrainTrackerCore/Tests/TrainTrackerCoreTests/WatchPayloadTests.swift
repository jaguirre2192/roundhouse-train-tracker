import Foundation
import Testing
@testable import TrainTrackerCore

struct WatchPayloadTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func train(id: String = "amtrak:2151", alighting: String? = "PHL") -> WidgetTripSnapshot.Train {
        func time(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        return WidgetTripSnapshot.Train(
            id: id, serviceName: "Acela 2151", boardingStationID: alighting == nil ? nil : "NYP", alightingStationID: alighting,
            stops: [
                WidgetTripSnapshot.Stop(
                    name: "New York Penn Station", code: "NYP", timeZoneIdentifier: "America/New_York",
                    scheduledDeparture: time(12), expectedDeparture: time(19), platform: "7", platformKind: .track
                ),
                WidgetTripSnapshot.Stop(
                    name: "Philadelphia 30th Street", code: "PHL", timeZoneIdentifier: "America/New_York",
                    scheduledArrival: time(92), expectedArrival: time(99), platform: "4", platformKind: .track
                ),
            ],
            lastSuccessfulCheck: now.addingTimeInterval(-120)
        )
    }

    private func payload() -> WatchPayload {
        WatchPayload(
            generatedAt: now,
            snapshot: WidgetTripSnapshot(generatedAt: now, trains: [train(), train(id: "amtrak:2155", alighting: nil)]),
            wakeAlerts: ["amtrak:2151": 10],
            wakeReplies: ["amtrak:2155": WatchWakeReply(requestID: "request-1", outcome: .notificationsDenied)]
        )
    }

    @Test func payloadRoundTripsThroughTheApplicationContext() throws {
        let sent = payload()
        let received = try #require(WatchPayload(context: try sent.context()))
        #expect(received == sent)
        #expect(received.snapshot.trains.map(\.id) == ["amtrak:2151", "amtrak:2155"])
        #expect(received.wakeAlerts == ["amtrak:2151": 10])
        #expect(received.wakeReplies["amtrak:2155"]?.outcome == .notificationsDenied)
    }

    @Test func contextHoldsOnlyPropertyListValues() throws {
        // WatchConnectivity rejects anything else, and archives the dictionary on the way.
        let context = try payload().context()
        #expect(PropertyListSerialization.propertyList(context, isValidFor: .binary))
        let data = try PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0)
        let revived = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(WatchPayload(context: revived) == payload())
    }

    @Test func emptyPayloadRoundTripsWithoutOptionalKeys() throws {
        let sent = WatchPayload(generatedAt: now, snapshot: WidgetTripSnapshot(generatedAt: now, trains: []))
        let context = try sent.context()
        #expect(context["wakeReplies"] == nil)
        let received = try #require(WatchPayload(context: context))
        #expect(received == sent)
        #expect(WidgetDisplay(snapshot: received.snapshot, at: now) == .empty)
    }

    @Test func unreadableContextsAreRejected() throws {
        #expect(WatchPayload(context: [:]) == nil)

        var otherVersion = try payload().context()
        otherVersion["v"] = WatchPayload.currentVersion + 1
        #expect(WatchPayload(context: otherVersion) == nil)

        var garbled = try payload().context()
        garbled["snapshot"] = Data("not a snapshot".utf8)
        #expect(WatchPayload(context: garbled) == nil)

        var otherSchema = try payload().context()
        let future = WidgetTripSnapshot(schemaVersion: WidgetTripSnapshot.currentSchemaVersion + 1, generatedAt: now, trains: [train()])
        otherSchema["snapshot"] = try WatchPayloadCoding.encoder.encode(future)
        #expect(WatchPayload(context: otherSchema) == nil)
    }

    @Test func unreadableRepliesDoNotDiscardTheTrains() throws {
        var context = try payload().context()
        context["wakeReplies"] = Data("not replies".utf8)
        let received = try #require(WatchPayload(context: context))
        #expect(received.wakeReplies.isEmpty)
        #expect(received.snapshot == payload().snapshot)
    }

    @Test func armRequestRoundTrips() throws {
        let request = WatchWakeRequest(id: "request-1", tripID: "amtrak:2151", stopID: "PHL", leadMinutes: 15, sentAt: now)
        let data = try PropertyListSerialization.data(fromPropertyList: request.userInfo, format: .binary, options: 0)
        let revived = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(WatchWakeRequest(userInfo: revived) == request)
    }

    @Test func disarmRequestForTheLastStopOmitsItsOptionalKeys() throws {
        let request = WatchWakeRequest(id: "request-2", tripID: "amtrak:2155", stopID: nil, leadMinutes: nil, sentAt: now)
        #expect(request.userInfo["leadMinutes"] == nil)
        #expect(request.userInfo["stopID"] == nil)
        let received = try #require(WatchWakeRequest(userInfo: request.userInfo))
        #expect(received == request)
        #expect(received.leadMinutes == nil)
    }

    @Test func requestsThePhoneShouldNotActOnAreRejected() {
        let good = WatchWakeRequest(id: "request-3", tripID: "amtrak:2151", stopID: "PHL", leadMinutes: 10, sentAt: now).userInfo
        #expect(WatchWakeRequest(userInfo: good) != nil)
        #expect(WatchWakeRequest(userInfo: [:]) == nil)
        #expect(WatchWakeRequest(userInfo: good.merging(["kind": "somethingElse"]) { $1 }) == nil)
        #expect(WatchWakeRequest(userInfo: good.merging(["tripID": ""]) { $1 }) == nil)
        #expect(WatchWakeRequest(userInfo: good.merging(["leadMinutes": 0]) { $1 }) == nil)
        #expect(WatchWakeRequest(userInfo: good.merging(["leadMinutes": "ten"]) { $1 }) == nil)
    }

    @Test func relayedCopyTurnsSavedOnceTheCheckIsOld() {
        let fresh = WidgetTrainPresentation(train: train(), at: now)
        #expect(fresh.trust == .estimated)
        #expect(fresh.relayedTrust == .estimated)
        #expect(fresh.compactTrustLine(fresh.relayedTrust) == "Estimated · 2 min ago")

        let later = WidgetTrainPresentation(train: train(), at: now.addingTimeInterval(14 * 60))
        #expect(later.relayedTrust == .saved)
        #expect(later.compactTrustLine(later.relayedTrust) == "Saved · 16 min ago")
    }

    @Test func onlyAnAnswerToThisRequestSettlesIt() {
        // A disarm is pending. A payload with no alert for the train looks like what was asked
        // for, but it may predate the request: it is not an answer.
        let disarm = WatchWakeRequest(tripID: "amtrak:2155", stopID: nil, leadMinutes: nil, sentAt: now)
        let unrelated = payload()
        #expect(unrelated.wakeAlerts["amtrak:2155"] == nil)
        #expect(unrelated.answer(to: disarm) == nil)

        var stale = unrelated
        stale.wakeReplies["amtrak:2155"] = WatchWakeReply(requestID: "an-earlier-request", outcome: .disarmed)
        #expect(stale.answer(to: disarm) == nil, "an answer to an earlier request is not this one's")

        var answered = unrelated
        answered.wakeReplies["amtrak:2155"] = WatchWakeReply(requestID: disarm.id, outcome: .disarmed)
        #expect(answered.answer(to: disarm)?.outcome == .disarmed)
    }
}
