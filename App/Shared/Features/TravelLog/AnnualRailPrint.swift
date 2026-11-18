import Foundation
import TrainTrackerCore

/// A dated edition drawn from one departure year in the rider's own Travel Log.
struct AnnualRailPrint {
    let year: Int
    let entries: [TravelLogEntry]
    let issued: Date
    let longest: AnnualRailJourney?
    let mappedDistance: Double
    let hasUnmeasuredRides: Bool
    let plates: [AnnualRailPlate]

    init?(year: Int, entries: [TravelLogEntry], plans: [TrackedJourneyPlan] = [],
          watching: Set<RailIdentifier> = [], issued: Date = .now) {
        var seen = Set<String>()
        let selected = entries.filter {
            $0.logYear == year && !watching.contains(RailIdentifier(rawValue: $0.id)) && seen.insert($0.id).inserted
        }.sorted {
            $0.departure == $1.departure ? $0.id < $1.id : $0.departure < $1.departure
        }
        guard !selected.isEmpty else { return nil }
        let routes = selected.compactMap(AnnualRailRoute.init)
        let measured = routes.map(\.entry).filter { $0.distanceMeters.isFinite && $0.distanceMeters > 0 }
        self.entries = selected
        self.issued = issued
        self.year = year
        longest = AnnualRailJourney.longest(in: measured, plans: plans)
        mappedDistance = measured.reduce(0) { $0 + $1.distanceMeters }
        hasUnmeasuredRides = measured.count != selected.count
        plates = AnnualRailPlate.group(routes)
    }

    var rideCountLabel: String {
        entries.count == 1 ? "1 ride" : "\(entries.count.formatted()) rides"
    }

    var longestLabel: String {
        if let longest, longest.rides.count > 1 {
            return hasUnmeasuredRides ? "Longest mapped journey" : "Longest journey"
        }
        return hasUnmeasuredRides ? "Longest mapped ride" : "Longest ride"
    }

    var distanceLabel: String? {
        guard mappedDistance > 0 else { return nil }
        let distance = TravelLogFormat.distance(mappedDistance)
        return hasUnmeasuredRides ? "About \(distance) mapped" : "About \(distance) by rail"
    }
}

extension TravelLogEntry {
    /// UTC is a stable fallback for old stubs without a station zone, even after the rider travels.
    var logTimeZone: TimeZone { originTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .gmt }

    var logDayLabel: String {
        let day = departureText(.dateTime.month(.abbreviated).day())
        return originTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) == nil ? "\(day) UTC" : day
    }

    var logYear: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = logTimeZone
        return calendar.component(.year, from: departure)
    }

    func departureText(_ format: Date.FormatStyle) -> String {
        var style = format
        style.timeZone = logTimeZone
        return departure.formatted(style)
    }
}

struct AnnualRailRoute {
    let entry: TravelLogEntry
    let points: [GeoCoordinate]

    init?(_ entry: TravelLogEntry) {
        let points = entry.path.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        guard let first = points.first, points.contains(where: { $0 != first }),
              points.allSatisfy(JourneyHistoryRouteTrace.valid) else { return nil }
        self.entry = entry
        self.points = points
    }
}
