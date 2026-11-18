import Foundation
import TrainTrackerCore

/// Calendar time, a train's GPS timestamp and the moment this device saw a change each say
/// something different. Only observations within this passenger's saved stops appear here.
struct TripUpdatePresentation {
    struct Line: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    let positionNote: Line?
    let changes: [Line]
    var headline: Line? { positionNote ?? changes.first }

    @MainActor init(experience: JourneyExperiencePresentation, journal: TripChangeJournal) {
        let trip = experience.trip
        let stops = experience.progress.stops
        guard !stops.isEmpty else { positionNote = nil; changes = []; return }
        let journal = journal.serviceDate == trip.serviceDate ? journal : TripChangeJournal()
        let focus = experience.progress.focusStop
        let destination = stops.last
        let now = experience.referenceDate
        func time(_ date: Date, at stop: StopTime?) -> String {
            let zone = stop.flatMap { experience.timeZones.timeZoneIdentifier(for: $0) ?? StationTimeZoneResolver.cached(for: $0.station.id)?.identifier }
            if let zone { return JourneyExperienceClock.labeledTime(date, zone: zone) }
            return "\(JourneyExperienceClock.time(date, zone: "GMT")) UTC"
        }
        func seen(_ date: Date, at stop: StopTime?, delivered: Bool) -> String {
            let zone = stop.flatMap { experience.timeZones.timeZoneIdentifier(for: $0) ?? StationTimeZoneResolver.cached(for: $0.station.id)?.identifier }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .gmt
            let day = calendar.isDate(date, inSameDayAs: now) ? "" : "\(JourneyExperienceClock.date(date, zone: calendar.timeZone.identifier)) · "
            return "\(delivered ? "Alert delivered" : "Seen") \(day)\(time(date, at: stop))"
        }
        let matchingCalls = Dictionary(grouping: stops, by: \.id)
        let preferred = Set([stops.first?.id, focus?.id, destination?.id].compactMap { $0 })
        changes = journal.timeline.flatMap { batch -> [Line] in
            batch.changes.enumerated().compactMap { index, change -> (Int, Line)? in
                let stop = change.callID.flatMap { matchingCalls[$0]?.first }
                if change.callID != nil && stop == nil { return nil }
                let callName = stop?.station.displayName
                let title: String, symbol: String, priority: Int
                switch change.fact {
                case let .platform(previous, value, noun):
                    title = previous.map { "\(noun) changed from \($0) to \(value)" } ?? "\(noun) \(value) announced"
                    symbol = "arrow.triangle.swap"; priority = preferred.contains(change.callID ?? "") ? 1 : 4
                case let .timing(minutes, arrival):
                    // A uniform delay across every station should read once, for the rider's arrival.
                    guard batch.receiptID != nil || stop?.id == destination?.id || (stop?.id == stops.first?.id && !arrival) else { return nil }
                    let event = arrival ? "Arrival" : "Departure"
                    let timing = minutes == 0 ? "on time" : "\(abs(minutes)) min \(minutes < 0 ? "early" : "late")"
                    title = "\(event) estimated \(timing)"
                    symbol = "clock"; priority = stop?.id == destination?.id ? 2 : 3
                case .stopCancelled: title = "Stop canceled"; symbol = "exclamationmark.circle"; priority = 0
                case .stopRestored: title = "Stop reinstated"; symbol = "checkmark.circle"; priority = 0
                case .cancelled: title = "Train canceled"; symbol = "exclamationmark.circle"; priority = 0
                case .restored: title = "Train reinstated"; symbol = "checkmark.circle"; priority = 0
                case .positionResumed: title = "Train position reporting again"; symbol = "dot.radiowaves.left.and.right"; priority = 5
                case .disruption: title = "Service disruption reported"; symbol = "exclamationmark.circle"; priority = 1
                }
                let detail = [callName, seen(batch.seenAt, at: stop ?? focus ?? destination, delivered: batch.receiptID != nil)]
                    .compactMap { $0 }.joined(separator: " · ")
                return (priority, Line(id: batch.receiptID ?? "\(batch.seenAt.timeIntervalSinceReferenceDate)-\(index)", title: title, detail: detail, symbol: symbol))
            }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let fix = TripChangeJournal.position(trip, at: now)
        let report = [fix?.asOf, journal.lastPositionReport].compactMap { $0 }.max()
        let progress = experience.progress
        guard !trip.isCancelled, !experience.hasCancelledBoundary, !progress.evidence.isArrivalConfirmed,
              progress.phase == .underway || (progress.phase == .ended && TripForegroundCadence.forTrip(trip, journal: journal, at: now) != nil),
              let report else { positionNote = nil; return }
        let basis = fix?.asOf == report ? fix?.timestampBasis : journal.lastPositionBasis
        let source = basis == .feedPublicationAndMovement ? "Position updated by the feed" : "Train position reported"
        if now.timeIntervalSince(report) > 300 || (trip.positions.isEmpty && journal.lastPositionReport != nil) {
            let arrival: String
            if let destination, let estimate = destination.expectedArrival ?? destination.expectedDeparture {
                let lead = experience.needsRefresh ? "Last arrival estimate" : "Estimated arrival"
                arrival = "\(lead) at \(destination.station.displayName) · \(time(estimate, at: destination))"
            } else if let destination, let scheduled = destination.scheduledArrival ?? destination.scheduledDeparture {
                arrival = "Timetable arrival at \(destination.station.displayName) · \(time(scheduled, at: destination))"
            } else { arrival = "Arrival time unavailable" }
            let prefix = basis == .feedPublicationAndMovement ? "Last feed position update" : "Last position reported"
            positionNote = Line(id: "last-position", title: "\(prefix) at \(time(report, at: focus ?? destination))", detail: arrival, symbol: "clock.arrow.circlepath")
        } else if progress.evidence.basis == .vehiclePosition, let focus, focus.id != stops.first?.id,
                  let scheduled = focus.scheduledArrival, scheduled < now,
                  !focus.hasConfirmedArrival(at: now), !progress.evidence.confirmedPassedStopIDs.contains(focus.id) {
            positionNote = Line(id: "unconfirmed-stop", title: "Arrival at \(focus.station.displayName) unconfirmed",
                                detail: "Timetable · \(time(scheduled, at: focus)). \(source) at \(time(report, at: focus)).", symbol: "location")
        } else { positionNote = nil }
    }
}
