import Foundation
import TrainTrackerCore

/// The number a rider can act on at their own boarding call. Forecasts, saved assignments
/// and timetable tracks never become the large station sign.
struct PlatformBoardPresentation {
    let station: String
    let noun: String
    let stationTerm: String?
    let number: String?
    let previous: String?
    let sourceText: String
    let departure: String
    let departureLabel: String

    init?(experience: JourneyExperiencePresentation, journal: TripChangeJournal = .init(), watching: Bool = false,
          plans: [TrackedJourneyPlan] = []) {
        let trip = experience.trip
        let progress = experience.progress
        if let leg = experience.selectedSegment {
            guard leg.resolvedTripID == trip.id, leg.kind == .rail, leg.unavailableReason == nil else { return nil }
        } else if plans.contains(where: { $0.outbound.childTripIDs.contains(trip.id) || $0.returnDirection?.childTripIDs.contains(trip.id) == true }) {
            // A saved plan with no unique selected leg cannot tell us where its passenger boards.
            return nil
        }
        guard !watching, !trip.isCancelled, !experience.hasCancelledBoundary,
              progress.phase == .upcoming || progress.phase == .departureSoon,
              !progress.evidence.isArrivalConfirmed, progress.evidence.confirmedPassedStopIDs.isEmpty,
              let stop = progress.stops.first, stop.id == progress.focusStop?.id,
              let date = stop.expectedDeparture ?? stop.scheduledDeparture else { return nil }
        // Some feeds supply more than one station name. Use the provider's explicitly
        // region-tagged form when available. Never translate a name into an invented sign.
        let regional = stop.station.names.first { entry in
            guard let tag = entry.localeIdentifier else { return false }
            return Locale(identifier: tag).region?.identifier.caseInsensitiveCompare(stop.station.countryCode) == .orderedSame
        }
        station = regional?.value ?? stop.station.displayName
        noun = stop.platformNoun
        stationTerm = Self.stationTerm(stop.station)
        let zone = experience.timeZones.timeZoneIdentifier(for: stop)
        departure = zone.map { JourneyExperienceClock.labeledTime(date, zone: $0) }
            ?? "\(JourneyExperienceClock.time(date, zone: "UTC")) UTC"
        let checked = experience.lastSuccessfulCheck
        let now = experience.referenceDate
        let fresh = !experience.refreshFailed && Self.fresh(checked, at: now)
        departureLabel = stop.expectedDeparture == nil ? "Timetable departure" : fresh ? "Estimated departure" : "Saved departure"
        let observation = stop.platformObservedAt ?? trip.sourceFetchedAt ?? checked
        let assignment = stop.platformGuidance(at: now)
        if case let .official(value, .current, changed) = assignment, fresh, Self.fresh(observation, at: now) {
            number = value
            previous = Self.previousNumber(journal: journal, trip: trip, stop: stop, value: value, now: now)
                ?? (changed ? stop.plannedPlatform?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            let feed = stop.platformSource?.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceText = feed.map { $0.isEmpty ? "Reported by the train feed" : "Reported by \($0)" } ?? "Reported by the train feed"
        } else {
            number = nil
            previous = nil
            switch assignment {
            case .official(let value, .scheduled, _):
                sourceText = "Timetable lists \(noun.lowercased()) \(value). Check station boards."
            case .official(_, .current, _):
                sourceText = "The last assignment is out of date. Check station boards."
            default:
                sourceText = "Check station boards for the announced \(noun.lowercased())."
            }
        }
    }

    private static func fresh(_ date: Date?, at now: Date) -> Bool {
        guard let age = date.map({ now.timeIntervalSince($0) }) else { return false }
        return (0..<300).contains(age)
    }

    /// The station's own public departure board supplies the local sign word. Other
    /// stations keep the supplied track/platform kind, including multilingual networks.
    private static func stationTerm(_ station: Station) -> String? {
        let codes = Set(station.codes.values).union([station.id.nativeID ?? station.id.rawValue])
        let names = Set(station.names.map {
            $0.value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        })
        switch station.countryCode.uppercased() {
        // bahnhof.de/berlin-hauptbahnhof/abfahrt
        case "DE" where codes.contains("8011160") || !names.isDisjoint(with: ["berlin hbf", "berlin hauptbahnhof"]): return "Gleis"
        // garesetconnexions.sncf/fr/gares-services/paris-gare-lyon
        case "FR" where codes.contains("87686006") || names.contains("paris gare de lyon"): return "Voie"
        // adif.es/w/60000-madrid-pta-de-atocha
        case "ES" where codes.contains("60000") || names.contains(where: { $0.hasPrefix("madrid puerta de atocha") }): return "Vía"
        default: return nil
        }
    }

    private static func previousNumber(journal: TripChangeJournal, trip: TrainTrip, stop: StopTime, value: String, now: Date) -> String? {
        guard journal.serviceDate == trip.serviceDate else { return nil }
        for batch in journal.timeline where batch.seenAt <= now {
            for change in batch.changes where change.callID == stop.id {
                if case let .platform(old, current, _) = change.fact {
                    // An older transition to today's number can belong to a superseded assignment.
                    return current == value && old != value ? old : nil
                }
            }
        }
        return nil
    }
}

struct PlatformBoardTicket: Identifiable {
    let ticket: LocalJourneyTicket
    let identifiesSeatForThisTrain: Bool
    var id: UUID { ticket.id }
    var coach: String? { identifiesSeatForThisTrain ? ticket.details.coach : nil }
    var seat: String? { identifiesSeatForThisTrain ? ticket.details.seat : nil }

    static func matching(_ tickets: [LocalJourneyTicket], tripID: RailIdentifier, plans: [TrackedJourneyPlan]) -> [Self] {
        // Ordinary imports attach the artifact to a journey. Through tickets remain readable,
        // but coach and seat fields on a multi-train booking can belong to another leg.
        let matching = plans.filter { plan in
            plan.outbound.childTripIDs.contains(tripID) || plan.returnDirection?.childTripIDs.contains(tripID) == true
        }
        return tickets.compactMap { ticket in
            let direct = ticket.linkedTripIDs.contains(tripID.rawValue)
            let linked = matching.filter { ticket.linkedPlanIDs.contains($0.id) }
            guard direct || !linked.isEmpty else { return nil }
            let oneTrain = linked.contains { plan in
                guard plan.returnDirection == nil, plan.outbound.childTripIDs == [tripID] else { return false }
                guard let segments = plan.outbound.selectedSegments else { return true }
                return segments.filter { $0.kind == .rail }.count == 1
            }
            return Self(ticket: ticket, identifiesSeatForThisTrain: direct || oneTrain)
        }
    }
}
