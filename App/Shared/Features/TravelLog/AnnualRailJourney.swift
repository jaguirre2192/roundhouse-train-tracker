import Foundation
import TrainTrackerCore

/// A booking can span trains. A longer claim needs the saved passenger sections and a stub for each ride.
struct AnnualRailJourney {
    let rides: [TravelLogEntry]

    var distanceMeters: Double { rides.reduce(0) { $0 + $1.distanceMeters } }
    var originName: String { rides[0].originName }
    var destinationName: String { rides[rides.count - 1].destinationName }
    var serviceLabel: String { rides.count == 1 ? rides[0].product : "\(rides.count.formatted()) train rides" }

    private init(rides: [TravelLogEntry]) { self.rides = rides }

    static func longest(in measured: [TravelLogEntry], plans: [TrackedJourneyPlan]) -> Self? {
        guard let single = measured.max(by: { $0.distanceMeters < $1.distanceMeters }) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: measured.map { ($0.id, $0) })
        var bookings: [[String]: Self] = [:]
        for plan in plans {
            for direction in [plan.outbound, plan.returnDirection].compactMap({ $0 }) {
                if let candidate = Self(direction, byID: byID) {
                    bookings[candidate.rides.map(\.id)] = candidate
                }
            }
        }
        // Two different complete itineraries can refer to the same stub after a replan. The
        // print cannot choose which booking the passenger took merely because one was longer.
        let references = bookings.keys.flatMap { $0 }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var longest = Self(rides: [single])
        for ids in bookings.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let candidate = bookings[ids], ids.allSatisfy({ references[$0] == 1 }) else { continue }
            if candidate.distanceMeters > longest.distanceMeters { longest = candidate }
        }
        return longest
    }

    private init?(_ direction: JourneyPlanDirection, byID: [String: TravelLogEntry]) {
        guard let segments = direction.selectedSegments,
              Set(segments.map(\.id)).count == segments.count,
              zip(segments, segments.dropFirst()).allSatisfy({ $0.to.id == $1.from.id }) else { return nil }
        let rail = segments.filter { $0.kind == .rail }
        let ids = rail.compactMap(\.resolvedTripID)
        guard rail.count > 1, ids.count == rail.count, Set(ids).count == ids.count,
              Set(ids) == Set(direction.childTripIDs) else { return nil }
        var matched: [TravelLogEntry] = []
        for (leg, id) in zip(rail, ids) {
            guard let ride = byID[id.rawValue],
                  Self.matches(leg.from, name: ride.originName, code: ride.originCode, point: ride.path.first),
                  Self.matches(leg.to, name: ride.destinationName, code: ride.destinationCode, point: ride.path.last),
                  matched.last.map({ $0.arrival <= ride.departure }) ?? true else { return nil }
            // Service identifiers can recur. A matching stop pair on another service day
            // cannot establish which booked train was ridden. Allow a delay across midnight.
            guard let planned = leg.departure, abs(ride.departure.timeIntervalSince(planned)) < 12 * 3_600 else { return nil }
            matched.append(ride)
        }
        self.init(rides: matched)
    }

    private static func matches(_ place: RailPlace, name: String, code: String?, point: TravelLogEntry.Point?) -> Bool {
        guard place.kind == .station, let point else { return false }
        let expected = place.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let namesMatch = !expected.isEmpty && actual.compare(expected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        let codesMatch = code.flatMap { code in
            place.id.nativeID.map { !code.isEmpty && code.caseInsensitiveCompare($0) == .orderedSame }
        } ?? false
        guard namesMatch || codesMatch else { return false }
        // Names and codes can also repeat. Require the mapped terminus to agree when the
        // booking carries coordinates, with room for a platform or a simplified track line.
        guard JourneyHistoryRouteTrace.valid(place.location) else { return namesMatch && codesMatch }
        let longitude = min(abs(place.location.longitude - point.longitude), 360 - abs(place.location.longitude - point.longitude))
        return abs(place.location.latitude - point.latitude) <= 0.015
            && longitude * cos(point.latitude * .pi / 180) <= 0.015
    }
}
