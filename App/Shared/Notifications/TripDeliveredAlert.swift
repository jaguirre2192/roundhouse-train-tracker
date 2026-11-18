import Foundation
import TrainTrackerCore
import UserNotifications

/// Only a typed Roundhouse push naming the exact provider run is evidence. The visible
/// notification prose and an unqualified train number cannot identify yesterday's train.
struct TripDeliveredAlert: Sendable {
    let id: String
    let tripID: RailIdentifier
    let serviceDate: Date
    let date: Date
    let stopID: String?
    private let kind: String
    private let previous: String?
    private let current: String
    private let timing: String?

    init?(userInfo: [AnyHashable: Any], date: Date) {
        guard let id = userInfo["eventID"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let trip = userInfo["tripID"] as? String, !trip.isEmpty,
              let day = userInfo["eventServiceDate"] as? String, day.count == 10,
              let serviceDate = WireDate.date(from: day), let kind = userInfo["eventKind"] as? String,
              ["platform-change", "delay-threshold", "cancellation", "disruption"].contains(kind),
              let value = userInfo["eventNewValue"] as? String, !value.isEmpty,
              date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        self.id = id; tripID = RailIdentifier(rawValue: trip); self.serviceDate = serviceDate; self.date = date
        stopID = userInfo["stopID"] as? String; self.kind = kind; previous = userInfo["eventOldValue"] as? String
        current = value; timing = userInfo["eventTiming"] as? String
    }

    init?(_ notification: UNNotification) {
        guard notification.request.trigger is UNPushNotificationTrigger else { return nil }
        self.init(userInfo: notification.request.content.userInfo, date: notification.date)
    }

    func change(for trip: TrainTrip, at date: Date) -> TripChangeJournal.Change? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard trip.id == tripID, calendar.isDate(serviceDate, inSameDayAs: trip.serviceDate) else { return nil }
        let calls = RailJourneyProgress(trip: trip, referenceDate: date).stops
        let stop: StopTime?
        if let stopID {
            // Earlier payloads named only the station; two visits to it are ambiguous.
            let matches = calls.filter { $0.station.id.rawValue == stopID }
            guard matches.count == 1 else { return nil }
            stop = matches[0]
        } else { stop = nil }
        let fact: TripChangeJournal.Fact
        switch kind {
        case "platform-change":
            guard let stop, current.count <= 32, (previous?.count ?? 0) <= 32 else { return nil }
            fact = .platform(previous: previous, current: current, noun: stop.platformNoun)
        case "delay-threshold":
            guard stop != nil, let minutes = Int(current), (0..<525_600).contains(minutes), timing == "arrival" || timing == "departure" else { return nil }
            fact = .timing(minutes: minutes, arrival: timing == "arrival")
        case "cancellation": fact = stop == nil ? .cancelled : .stopCancelled
        case "disruption": fact = .disruption
        default: return nil
        }
        return .init(callID: stop?.id, fact: fact)
    }

    @MainActor static func readDelivered(into library: TripLibrary) async {
        guard !library.trips.isEmpty else { return }
        let alerts: [TripDeliveredAlert] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.compactMap(TripDeliveredAlert.init))
            }
        }
        try? library.keepDeliveredAlerts(alerts)
    }
}
