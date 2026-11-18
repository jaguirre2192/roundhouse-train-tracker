import Foundation
import TrainTrackerCore

/// A bounded record of what this device saw on consecutive checks. Check times and the
/// provider's vehicle timestamp are separate clocks. A missing estimate is never zero delay.
struct TripChangeJournal: Codable, Equatable {
    struct Batch: Codable, Equatable {
        let seenAt: Date
        let changes: [Change]
        var since: Date? = nil
        var receiptID: String? = nil
    }

    struct Change: Codable, Equatable {
        var callID: String? = nil
        let fact: Fact
    }

    enum Fact: Codable, Equatable {
        case platform(previous: String?, current: String, noun: String)
        case timing(minutes: Int, arrival: Bool)
        case stopCancelled, stopRestored, cancelled, restored, positionResumed, disruption
    }

    private(set) var serviceDate: Date?
    private(set) var lastPositionReport: Date?
    private(set) var lastPositionBasis: PositionTimestampBasis?
    private(set) var foregroundRecovery: TripForegroundRecovery?
    private(set) var batches: [Batch] = []
    private var deliveries: [Batch] = []
    /// Remember the last delay we printed so that a delay growing a minute at a time counts.
    private var delayBaselines: [String: Int] = [:]
    private var lastPlatforms: [String: String] = [:]
    private var hasSeenPositionGap = false
    private var newestSnapshotAt: Date?

    init() {}

    mutating func observe(previous: TrainTrip, current: TrainTrip, hadConfirmedCheck: Bool, at date: Date, since previousCheck: Date? = nil) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        let sameRun = current.id == previous.id && current.serviceDate == previous.serviceDate
        if serviceDate != current.serviceDate {
            self = Self()
            serviceDate = current.serviceDate
        }
        if sameRun, previous.source == current.source, hadConfirmedCheck, foregroundRecovery == nil {
            foregroundRecovery = TripForegroundRecovery.observing(nil, trip: previous, at: date)
        }
        foregroundRecovery = TripForegroundRecovery.observing(foregroundRecovery, trip: current, at: date)
        var changes: [Change] = []
        if sameRun, hadConfirmedCheck, lastPositionReport == nil {
            let fix = Self.position(previous, at: date)
            lastPositionReport = fix?.asOf
            lastPositionBasis = fix?.timestampBasis
        }
        if let fix = Self.position(current, at: date), fix.asOf > (lastPositionReport ?? .distantPast) {
            if hasSeenPositionGap, RailJourneyEvidence.freshPosition(in: current, at: date) != nil {
                changes.append(Change(fact: .positionResumed))
            }
            lastPositionReport = fix.asOf
            lastPositionBasis = fix.timestampBasis
        }
        if let report = lastPositionReport { hasSeenPositionGap = date.timeIntervalSince(report) > 300 }

        // An older retained response cannot establish a new operational change. Position
        // overlays have their own clock and can still update independently above.
        let retainedPrevious = newestSnapshotAt.flatMap { latest in previous.sourceFetchedAt.map { $0 < latest } } ?? false
        if sameRun, hadConfirmedCheck, !retainedPrevious, !Self.isEarlierSnapshot(current, than: previous) {
            changes += callChanges(previous: previous, current: current, at: date)
        }
        if let fetched = current.sourceFetchedAt, fetched <= date, fetched > (newestSnapshotAt ?? .distantPast) {
            newestSnapshotAt = fetched
        }
        guard !changes.isEmpty else { return }
        batches.insert(Batch(seenAt: date, changes: changes, since: previousCheck), at: 0)
        if batches.count > 12 { batches.removeLast(batches.count - 12) }
    }

    /// Alerts delivered while the app was asleep keep the system's delivery time. Correlate
    /// one exact transition and call with one local check of the same interval.
    var timeline: [Batch] {
        guard !deliveries.isEmpty else { return batches }
        var used = Set<String>()
        let local = batches.compactMap { batch -> Batch? in
            guard let since = batch.since else { return batch }
            let remaining = batch.changes.filter { change in
                guard let delivery = deliveries.first(where: { row in
                    row.changes.first == change && row.seenAt >= since &&
                    row.seenAt <= batch.seenAt.addingTimeInterval(15 * 60) &&
                    row.receiptID.map { !used.contains($0) } == true
                }), let id = delivery.receiptID else { return true }
                used.insert(id)
                return false
            }
            return remaining.isEmpty ? nil : Batch(seenAt: batch.seenAt, changes: remaining, since: since)
        }
        return (local + deliveries).sorted { $0.seenAt > $1.seenAt }
    }

    mutating func accept(_ receipt: TripDeliveredAlert, for trip: TrainTrip, at date: Date) -> Bool {
        guard receipt.date <= date, let change = receipt.change(for: trip, at: date) else { return false }
        if serviceDate != trip.serviceDate {
            self = Self()
            serviceDate = trip.serviceDate
        }
        guard !deliveries.contains(where: { $0.receiptID == receipt.id }),
              deliveries.count < 12 || receipt.date > (deliveries.last?.seenAt ?? .distantPast) else { return false }
        deliveries.append(Batch(seenAt: receipt.date, changes: [change], receiptID: receipt.id))
        deliveries.sort { $0.seenAt > $1.seenAt }
        if deliveries.count > 12 { deliveries.removeLast() }
        return true
    }

    static func position(_ trip: TrainTrip, at date: Date) -> VehiclePosition? {
        RailJourneyEvidence.latestRealPosition(in: trip, at: date, maximumAge: .greatestFiniteMagnitude)
            .flatMap { $0.asOf <= date ? $0 : nil }
    }

    private static func isEarlierSnapshot(_ new: TrainTrip, than old: TrainTrip) -> Bool {
        guard let newDate = new.sourceFetchedAt, let oldDate = old.sourceFetchedAt else { return false }
        return newDate < oldDate
    }

    private mutating func callChanges(previous: TrainTrip, current: TrainTrip, at date: Date) -> [Change] {
        guard !previous.stopTimes.isEmpty, !current.stopTimes.isEmpty else { return [] }
        if current.isCancelled != previous.isCancelled {
            return [Change(fact: current.isCancelled ? .cancelled : .restored)]
        }
        guard !current.isCancelled else { return [] }
        // Match the same physical call used by the passenger's progress, including providers
        // which send adjacent arrival-only and departure-only rows for a single stop.
        let oldCalls = Dictionary(grouping: RailJourneyProgress(trip: previous, referenceDate: date).stops, by: \.id)
        let currentCalls = RailJourneyProgress(trip: current, referenceDate: date).stops
        let ids = Set(currentCalls.map(\.id))
        delayBaselines = delayBaselines.filter { ids.contains($0.key) }
        lastPlatforms = lastPlatforms.filter { ids.contains($0.key) }
        var changes: [Change] = []
        for call in currentCalls {
            guard let matches = oldCalls[call.id], matches.count == 1, let old = matches.first else { continue }
            if call.isCancelled != old.isCancelled {
                changes.append(Change(callID: call.id, fact: call.isCancelled ? .stopCancelled : .stopRestored))
            }
            guard !call.isCancelled else { continue }
            let prior = lastPlatforms[call.id] ?? normalized(old.expectedPlatform)
            lastPlatforms[call.id] = normalized(call.expectedPlatform) ?? prior
            if let value = normalized(call.expectedPlatform), value != prior {
                changes.append(Change(callID: call.id, fact: .platform(previous: prior, current: value, noun: call.platformNoun)))
            }
            let arrival = call.scheduledArrival != nil
            guard let minutes = Self.delay(call, arrival: arrival) else { continue }
            let baseline = delayBaselines[call.id] ?? Self.delay(old, arrival: arrival)
            delayBaselines[call.id] = baseline ?? minutes
            // Becoming delayed or returning to on time matters even on a small change;
            // otherwise wait until the estimate itself has moved at least five minutes.
            guard baseline.map({ abs(minutes - $0) >= 5 || (minutes >= 5) != ($0 >= 5) }) ?? (minutes >= 5) else { continue }
            delayBaselines[call.id] = minutes
            changes.append(Change(callID: call.id, fact: .timing(minutes: minutes, arrival: arrival)))
        }
        return changes
    }

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func delay(_ call: StopTime, arrival: Bool) -> Int? {
        let expected = arrival ? call.expectedArrival : call.expectedDeparture
        let scheduled = arrival ? call.scheduledArrival : call.scheduledDeparture
        guard let expected, let scheduled else { return nil }
        let minutes = (expected.timeIntervalSince(scheduled) / 60).rounded()
        guard minutes.isFinite, abs(minutes) < 365 * 24 * 60 else { return nil }
        return Int(minutes)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension TripChangeJournal {
    /// Older saved trips may retain a verifiable coordinate or dated stop, even when their
    /// journal predates this field. A bare saved timestamp cannot place a train on its route.
    func recoveryForPolling(_ trip: TrainTrip, at date: Date) -> TripForegroundRecovery? {
        if serviceDate == trip.serviceDate, let foregroundRecovery { return foregroundRecovery }
        return TripForegroundRecovery.observing(nil, trip: trip, at: date)
    }

    mutating func reserveSlowCheck(for trip: TrainTrip, at date: Date, lastSuccess: Date?) -> Bool {
        guard var state = recoveryForPolling(trip, at: date), state.cadence(for: trip, at: date) == .occasional else { return false }
        guard state.checkIsDue(at: date, lastSuccess: lastSuccess) else { return false }
        if serviceDate != trip.serviceDate {
            self = Self()
            serviceDate = trip.serviceDate
        }
        state.lastSlowAttempt = date
        foregroundRecovery = state
        return true
    }
}
