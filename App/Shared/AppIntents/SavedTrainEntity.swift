import AppIntents
import Foundation
import TrainTrackerCore

struct SavedTrainEntity: IndexedEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved train"
    static let defaultQuery = SavedTrainQuery()

    let id: String
    let serviceName: String
    let originName: String
    let destinationName: String
    let departureDate: Date
    let timeZoneIdentifier: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(serviceName)",
            subtitle: "\(originName) to \(destinationName) · \(departureDescription)",
            image: .init(systemName: "tram.fill")
        )
    }

    var departureDescription: String {
        guard departureDate.timeIntervalSinceReferenceDate.isFinite else { return "Date unavailable" }
        let formatter = DateFormatter()
        formatter.locale = .trainTrackerTime
        formatter.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let date = formatter.string(from: departureDate)
        let zone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        return "\(date) \(zone?.abbreviation(for: departureDate) ?? "UTC")"
    }

    fileprivate var searchText: String {
        [serviceName, originName, destinationName, departureDescription].joined(separator: " ")
    }
}

/// A fresh value snapshot; it owns no archive, network client, or mutable store.
struct SavedTrainEntityCatalog: Sendable {
    private let entries: [Entry]
    private let referenceDate: Date

    init(trips: [TrainTrip], plans: [TrackedJourneyPlan] = [], referenceDate: Date = .now) {
        self.referenceDate = referenceDate
        var seen: Set<String> = []
        entries = trips.filter { seen.insert($0.id.rawValue).inserted }.map { trip in
            let segment = JourneyTripContext.selectedSegment(for: trip.id, plans: plans)
            let progress: RailJourneyProgress
            if let segment {
                progress = RailJourneyProgress(
                    trip: trip,
                    referenceDate: referenceDate,
                    boardingPlace: segment.from,
                    alightingPlace: segment.to
                )
            } else {
                progress = RailJourneyProgress(trip: trip, referenceDate: referenceDate)
            }
            let boarding = progress.stops.first ?? trip.stopTimes.first
            let alighting = progress.stops.last ?? trip.stopTimes.last
            let zones = TripDetailTimeZoneContext(trip: trip, plans: plans)
            let departure = boarding?.scheduledDeparture ?? boarding?.scheduledArrival
                ?? progress.departureDate ?? trip.serviceDate
            let entity = SavedTrainEntity(
                id: trip.id.rawValue, serviceName: trip.product.isEmpty ? "Train" : trip.product,
                originName: boarding?.station.displayName ?? "Origin unavailable",
                destinationName: alighting?.station.displayName ?? "Destination unavailable",
                departureDate: departure,
                timeZoneIdentifier: boarding.flatMap { zones.timeZoneIdentifier(for: $0) }
            )
            return Entry(entity: entity, departure: progress.departureDate, arrival: progress.arrivalDate)
        }
    }

    func entities(for identifiers: [String]) -> [SavedTrainEntity] {
        let indexed = Dictionary(uniqueKeysWithValues: entries.map { ($0.entity.id, $0.entity) })
        var seen: Set<String> = []
        return identifiers.filter { seen.insert($0).inserted }.compactMap { indexed[$0] }
    }

    func allEntities() -> [SavedTrainEntity] {
        entries.map(\.entity)
    }

    func entities(matching string: String) -> [SavedTrainEntity] {
        let terms = string.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return suggestedEntities() }
        return entries.map(\.entity).filter { entity in
            terms.allSatisfy { entity.searchText.localizedStandardContains($0) }
        }
    }

    func suggestedEntities() -> [SavedTrainEntity] {
        entries.filter { entry in
            guard let departure = entry.departure, let arrival = entry.arrival,
                  departure.timeIntervalSinceReferenceDate.isFinite,
                  arrival.timeIntervalSinceReferenceDate.isFinite else { return false }
            return arrival >= departure && arrival > referenceDate
        }.sorted {
            if $0.departure == $1.departure { return $0.entity.id < $1.entity.id }
            return ($0.departure ?? .distantFuture) < ($1.departure ?? .distantFuture)
        }.map(\.entity)
    }

    private struct Entry: Sendable {
        let entity: SavedTrainEntity
        let departure: Date?
        let arrival: Date?
    }
}
