import CoreLocation
import Foundation
import Observation
import TrainTrackerCore

/// One finished journey, kept as a ticket stub: where, when, how far and how long. It holds its
/// own copy of what it needs, so it survives the train being removed from My Trips.
struct TravelLogEntry: Codable, Identifiable, Hashable, Sendable {
    struct Point: Codable, Hashable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    let id: String
    let product: String
    let operatorName: String
    let originName: String
    let originCode: String?
    let destinationName: String
    let destinationCode: String?
    let departure: Date
    let arrival: Date
    let distanceMeters: Double
    let stopCount: Int
    /// Minutes late at the destination; zero or less is on time.
    let arrivalDelayMinutes: Int
    /// The line ridden, thinned for the map.
    let path: [Point]
    /// True only when the arrival was reported when the stub was kept. Nil on stubs kept
    /// before this was recorded: they were kept by the clock, which proves nothing.
    var arrivalReported: Bool? = nil
    /// The passenger's boarding station. Older stubs did not keep a zone.
    var originTimeZoneIdentifier: String? = nil

    /// Whether the stub may say the train arrived.
    var isArrivalConfirmed: Bool { arrivalReported ?? false }

    var duration: TimeInterval { max(arrival.timeIntervalSince(departure), 0) }
    var originLabel: String { originCode ?? originName }
    var destinationLabel: String { destinationCode ?? destinationName }
}

extension TravelLogEntry {
    /// The stub for a finished train: the stops the passenger rode, the line between them, and
    /// the latest times known for each end. Those are estimates or timetable times, not
    /// observed ones, even when the arrival itself was reported.
    init?(trip: TrainTrip, stops: [StopTime], arrivalConfirmed: Bool, departureTimeZone: TimeZone? = nil) {
        guard let first = stops.first, let last = stops.last, first.id != last.id, !trip.isCancelled,
              let departure = first.expectedDeparture ?? first.scheduledDeparture ?? first.expectedArrival ?? first.scheduledArrival,
              let arrival = last.expectedArrival ?? last.scheduledArrival ?? last.expectedDeparture ?? last.scheduledDeparture,
              arrival > departure else { return nil }

        let stopCoordinates = stops.map { CLLocationCoordinate2D(latitude: $0.station.location.latitude, longitude: $0.station.location.longitude) }
        var line = stopCoordinates
        if let geometry = trip.routeGeometry, geometry.coordinates.count > 1,
           let route = RoutePath(coordinates: geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }) {
            let start = route.projection(of: stopCoordinates[0])
            let end = route.projection(of: stopCoordinates[stopCoordinates.count - 1])
            // Only trust the track line when both stations actually sit on it.
            if start.offset < TrainGlide.largestOffset, end.offset < TrainGlide.largestOffset, end.distance > start.distance {
                line = route.slice(from: start.distance, to: end.distance)
            }
        }
        let distance = zip(line, line.dropFirst()).reduce(0.0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        let stride = max(line.count / 96, 1)
        var thinned = line.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        if let end = line.last, thinned.last.map({ $0.latitude != end.latitude || $0.longitude != end.longitude }) ?? true {
            thinned.append(end)
        }
        let scheduledArrival = last.scheduledArrival ?? last.scheduledDeparture

        self.init(
            id: trip.id.rawValue,
            product: trip.product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trip.operatorName : trip.product,
            operatorName: trip.operatorName,
            originName: first.station.displayName,
            originCode: StationShortCode.code(for: first.station),
            destinationName: last.station.displayName,
            destinationCode: StationShortCode.code(for: last.station),
            departure: departure,
            arrival: arrival,
            distanceMeters: distance,
            stopCount: stops.count,
            arrivalDelayMinutes: scheduledArrival.map { Int(arrival.timeIntervalSince($0) / 60) } ?? 0,
            path: thinned.map { Point(latitude: $0.latitude, longitude: $0.longitude) },
            arrivalReported: arrivalConfirmed,
            originTimeZoneIdentifier: departureTimeZone?.identifier
        )
    }
}

/// Every journey finished while it was tracked, newest first. Kept on this device.
@MainActor
@Observable
final class TravelLog {
    /// On fixture data the log lives in memory and never touches the rider's own; App Store
    /// previews start it filled.
    static let shared: TravelLog = {
        guard LaunchFixtures.isActive else { return TravelLog() }
        let isStorePreview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-AppStorePreview") }
        return TravelLog(seed: isStorePreview ? TravelLogEntry.previewSamples : [])
    }()

    private(set) var entries: [TravelLogEntry] = []
    @ObservationIgnored private let fileURL: URL?

    struct Totals: Equatable {
        var journeys = 0
        var distanceMeters = 0.0
        var duration: TimeInterval = 0
        var stations = 0
    }

    init(fileURL: URL? = TravelLog.defaultFileURL, seed: [TravelLogEntry]? = nil) {
        self.fileURL = seed == nil ? fileURL : nil
        if let seed {
            entries = seed
        } else if let fileURL, let data = try? Data(contentsOf: fileURL),
                  let saved = try? JSONDecoder().decode([TravelLogEntry].self, from: data) {
            entries = saved
        }
    }

    nonisolated static var defaultFileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TravelLog.json")
    }

    func contains(_ id: String) -> Bool { entries.contains { $0.id == id } }

    func entry(id: String) -> TravelLogEntry? { entries.first { $0.id == id } }

    /// Adds a stub once; a journey already in the log is left as it was first recorded. The one
    /// exception: a stub kept on the timetable alone is replaced when the arrival is reported.
    @discardableResult
    func record(_ entry: TravelLogEntry) -> Bool {
        if let existing = self.entry(id: entry.id) {
            guard !existing.isArrivalConfirmed, entry.isArrivalConfirmed else { return false }
            entries.removeAll { $0.id == entry.id }
        }
        entries.append(entry)
        entries.sort { $0.arrival > $1.arrival }
        save()
        return true
    }

    func remove(id: String) {
        try? removePersisting(id: id)
    }

    func removePersisting(id: String) throws {
        guard contains(id) else { return }
        let remaining = entries.filter { $0.id != id }
        if let fileURL { try JSONEncoder().encode(remaining).write(to: fileURL, options: .atomic) }
        entries = remaining
    }

    var totals: Totals {
        var totals = Totals()
        var stations = Set<String>()
        for entry in entries {
            totals.journeys += 1
            totals.distanceMeters += entry.distanceMeters
            totals.duration += entry.duration
            stations.insert(entry.originName)
            stations.insert(entry.destinationName)
        }
        totals.stations = stations.count
        return totals
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum TravelLogFormat {
    /// "225 mi" or "362 km", by the device's region.
    static func distance(_ meters: Double, locale: Locale = .autoupdatingCurrent) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(
            .measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0)))
            .locale(locale)
        )
    }

    /// "3 h 38 min" or "42 min".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// Whole hours for the totals; under an hour stays in minutes.
    static func hours(_ interval: TimeInterval) -> (value: String, unit: String) {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return ("\(minutes)", "Minutes") }
        return ((interval / 3600).formatted(.number.precision(.fractionLength(interval < 36_000 ? 1 : 0))), "Hours")
    }
}

extension TravelLogEntry {
    /// Three finished journeys for previews and screenshots.
    static var previewSamples: [TravelLogEntry] {
        func entry(
            _ id: String, _ product: String, _ origin: (String, String), _ destination: (String, String),
            daysAgo: Double, hours: Double, kilometers: Double, stops: Int, delay: Int, zone: String, path: [(Double, Double)]
        ) -> TravelLogEntry {
            let departure = Date.now.addingTimeInterval(-daysAgo * 86_400)
            return TravelLogEntry(
                id: id, product: product, operatorName: "Amtrak",
                originName: origin.0, originCode: origin.1, destinationName: destination.0, destinationCode: destination.1,
                departure: departure, arrival: departure.addingTimeInterval(hours * 3_600),
                distanceMeters: kilometers * 1_000, stopCount: stops, arrivalDelayMinutes: delay,
                path: path.map { Point(latitude: $0.0, longitude: $0.1) },
                arrivalReported: true, originTimeZoneIdentifier: zone
            )
        }
        return [
            entry("preview-acela", "Acela 2155", ("Boston South", "BOS"), ("New York Penn", "NYP"),
                  daysAgo: 6, hours: 3.7, kilometers: 372, stops: 6, delay: 0, zone: "America/New_York",
                  path: [(42.352, -71.055), (41.824, -71.413), (41.298, -72.927), (41.047, -73.541), (40.750, -73.993)]),
            entry("preview-surfliner", "Pacific Surfliner 774", ("Los Angeles Union", "LAX"), ("San Diego", "SAN"),
                  daysAgo: 19, hours: 2.9, kilometers: 206, stops: 9, delay: 11, zone: "America/Los_Angeles",
                  path: [(34.056, -118.235), (33.870, -117.924), (33.502, -117.663), (33.193, -117.380), (32.716, -117.170)]),
            entry("preview-hiawatha", "Hiawatha 335", ("Chicago Union", "CHI"), ("Milwaukee", "MKE"),
                  daysAgo: 41, hours: 1.5, kilometers: 138, stops: 5, delay: 2, zone: "America/Chicago",
                  path: [(41.879, -87.640), (42.073, -87.806), (42.719, -87.906), (43.034, -87.917)]),
        ]
    }
}
