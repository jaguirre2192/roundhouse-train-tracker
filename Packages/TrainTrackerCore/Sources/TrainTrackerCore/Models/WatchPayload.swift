import Foundation

/// What the iPhone app sends the Apple Watch app after each snapshot write, as a
/// WatchConnectivity application context: the rider's next trains, which of them have a
/// wake alert armed on the phone, and the phone's answer to the watch's last wake request
/// for each train. Pure Foundation so both sides compile it and it can be tested.
public struct WatchPayload: Equatable, Sendable {
    public static let currentVersion = 1

    public var generatedAt: Date
    public var snapshot: WidgetTripSnapshot
    /// Wake alerts armed on the phone: trip ID to minutes of lead.
    public var wakeAlerts: [String: Int]
    /// The phone's answer to the latest wake request it handled, by trip ID.
    public var wakeReplies: [String: WatchWakeReply]

    public init(
        generatedAt: Date,
        snapshot: WidgetTripSnapshot,
        wakeAlerts: [String: Int] = [:],
        wakeReplies: [String: WatchWakeReply] = [:]
    ) {
        self.generatedAt = generatedAt
        self.snapshot = snapshot
        self.wakeAlerts = wakeAlerts
        self.wakeReplies = wakeReplies
    }

    // MARK: Application context

    private enum Key {
        static let version = "v"
        static let generatedAt = "generatedAt"
        static let snapshot = "snapshot"
        static let wakeAlerts = "wake"
        static let wakeReplies = "wakeReplies"
    }

    /// The property-list dictionary for `WCSession.updateApplicationContext`. The snapshot
    /// travels as its JSON, the same encoding the widgets read from the App Group.
    public func context() throws -> [String: Any] {
        var context: [String: Any] = [
            Key.version: Self.currentVersion,
            Key.generatedAt: generatedAt.timeIntervalSince1970,
            Key.snapshot: try WatchPayloadCoding.encoder.encode(snapshot),
            Key.wakeAlerts: wakeAlerts,
        ]
        if !wakeReplies.isEmpty {
            context[Key.wakeReplies] = try WatchPayloadCoding.encoder.encode(wakeReplies)
        }
        return context
    }

    /// Nil when the context is empty, from another version, or its snapshot cannot be read.
    public init?(context: [String: Any]) {
        guard context[Key.version] as? Int == Self.currentVersion,
              let generatedAt = context[Key.generatedAt] as? Double,
              let data = context[Key.snapshot] as? Data,
              let snapshot = try? WatchPayloadCoding.decoder.decode(WidgetTripSnapshot.self, from: data),
              snapshot.schemaVersion == WidgetTripSnapshot.currentSchemaVersion
        else { return nil }
        self.generatedAt = Date(timeIntervalSince1970: generatedAt)
        self.snapshot = snapshot
        self.wakeAlerts = context[Key.wakeAlerts] as? [String: Int] ?? [:]
        let replies = (context[Key.wakeReplies] as? Data).flatMap {
            try? WatchPayloadCoding.decoder.decode([String: WatchWakeReply].self, from: $0)
        }
        self.wakeReplies = replies ?? [:]
    }
}

/// The phone's answer to one wake request from the watch.
public struct WatchWakeReply: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case armed
        case disarmed
        /// Notifications are off for the app on the phone, so it cannot sound an alert.
        case notificationsDenied
        /// The train has already reached the stop, or was cancelled.
        case stopNotAhead
        /// The phone no longer tracks this train.
        case tripNotFound
        /// The phone has to ask the rider something first, which it can only do when open.
        case needsPhone
    }

    /// The `WatchWakeRequest.id` this answers.
    public let requestID: String
    public let outcome: Outcome

    public init(requestID: String, outcome: Outcome) {
        self.requestID = requestID
        self.outcome = outcome
    }
}

public extension WatchPayload {
    /// The phone's answer to `request`, and only to it. A payload that merely happens to show
    /// the state the request asked for (no alert, say, while a disarm is pending) is not an
    /// answer: it may predate the request.
    func answer(to request: WatchWakeRequest) -> WatchWakeReply? {
        guard let reply = wakeReplies[request.tripID], reply.requestID == request.id else { return nil }
        return reply
    }
}

/// What the watch asks of the phone: arm the wake alert for a train's stop with a lead time,
/// or disarm it. Sent with `WCSession.transferUserInfo`, which queues while the phone is out
/// of reach.
public struct WatchWakeRequest: Equatable, Sendable {
    public static let kind = "wakeRequest"
    /// The lead times the watch offers, matching the phone's `StopWakeAlerts.leadChoices`.
    public static let leadChoices = [5, 10, 15]
    public static let defaultLead = 10

    public let id: String
    public let tripID: String
    /// The stop the rider gets off at; nil means the train's last stop, which the phone knows.
    public let stopID: String?
    /// Minutes of lead to arm with; nil to disarm.
    public let leadMinutes: Int?
    public let sentAt: Date

    public init(id: String = UUID().uuidString, tripID: String, stopID: String?, leadMinutes: Int?, sentAt: Date) {
        self.id = id
        self.tripID = tripID
        self.stopID = stopID
        self.leadMinutes = leadMinutes
        self.sentAt = sentAt
    }

    private enum Key {
        static let kind = "kind"
        static let id = "id"
        static let tripID = "tripID"
        static let stopID = "stopID"
        static let leadMinutes = "leadMinutes"
        static let sentAt = "sentAt"
    }

    /// The property-list dictionary for `WCSession.transferUserInfo`. Absent keys mean nil.
    public var userInfo: [String: Any] {
        var info: [String: Any] = [
            Key.kind: Self.kind,
            Key.id: id,
            Key.tripID: tripID,
            Key.sentAt: sentAt.timeIntervalSince1970,
        ]
        if let stopID { info[Key.stopID] = stopID }
        if let leadMinutes { info[Key.leadMinutes] = leadMinutes }
        return info
    }

    public init?(userInfo: [String: Any]) {
        guard userInfo[Key.kind] as? String == Self.kind,
              let id = userInfo[Key.id] as? String, !id.isEmpty,
              let tripID = userInfo[Key.tripID] as? String, !tripID.isEmpty,
              let sentAt = userInfo[Key.sentAt] as? Double
        else { return nil }
        // A lead outside what the phone offers is not a request the phone should act on.
        if let lead = userInfo[Key.leadMinutes], (lead as? Int).map({ $0 > 0 && $0 <= 120 }) != true { return nil }
        self.id = id
        self.tripID = tripID
        self.stopID = userInfo[Key.stopID] as? String
        self.leadMinutes = userInfo[Key.leadMinutes] as? Int
        self.sentAt = Date(timeIntervalSince1970: sentAt)
    }
}

enum WatchPayloadCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
