import Foundation
import TrainTrackerCore

/// An early duplicate shortcut needs the same passenger stations and one distinct service.
/// Otherwise normal station lookup and journey fingerprints decide after the person reviews.
enum ImportedSavedJourneyMatcher {
    static func match(
        origin: String, destination: String, trainNumber: String,
        departure: TicketWallClock?, departureInstant: Date?, knownTimeZone: TimeZone?,
        plans: [TrackedJourneyPlan], originPlace: RailPlace?, destinationPlace: RailPlace?
    ) -> TrackedJourneyPlan? {
        guard let departure, departure.hasTime else { return nil }
        let number = ImportedStationMatcher.key(trainNumber)
        // A bare name and minute do not identify an unnumbered service before station lookup.
        guard !number.isEmpty || (originPlace != nil && destinationPlace != nil) else { return nil }
        var matches: [(plan: TrackedJourneyPlan, fingerprint: String)] = []
        for plan in plans {
            for direction in [plan.outbound, plan.returnDirection].compactMap({ $0 }) {
                let rails = (direction.selectedSegments ?? []).filter { $0.kind == .rail }
                // One supplied train number cannot establish the onward connection. Let the
                // full search/review compare fingerprints for journeys with several segments.
                guard direction.selectedSegments?.count == 1, rails.count == 1,
                      let start = rails.first?.from, let end = rails.last?.to,
                      matchesStation(origin, selected: originPlace, candidate: start),
                      matchesStation(destination, selected: destinationPlace, candidate: end),
                      let zone = knownTimeZone ?? TimeZone(identifier: start.timeZoneIdentifier),
                      let date = departureInstant ?? departure.date(in: zone),
                      abs(date.timeIntervalSince(direction.departure)) <= 60 else { continue }
                if !number.isEmpty {
                    let services = rails.compactMap(\.serviceName).map(ImportedStationMatcher.key)
                    guard services.contains(where: { (" " + $0 + " ").contains(" " + number + " ") }) else { continue }
                }
                matches.append((plan, direction.fingerprint))
            }
        }
        guard let first = matches.first, !first.fingerprint.isEmpty,
              Set(matches.map(\.fingerprint)).count == 1 else { return nil }
        return first.plan
    }

    private static func matchesStation(_ name: String, selected: RailPlace?, candidate: RailPlace) -> Bool {
        if let selected { return selected.id == candidate.id }
        return ImportedStationMatcher.bestPlace(named: name, from: [candidate]) != nil
    }
}
