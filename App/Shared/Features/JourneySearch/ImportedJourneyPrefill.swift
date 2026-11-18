import Foundation
import TrainTrackerCore

struct ImportedJourneyPrefill {
    let origin: RailPlace?
    let destination: RailPlace?
    let departureTime: Date?
    let directReview: ImportedJourneyAutoSelection?

    @MainActor
    static func resolve(
        _ request: TicketJourneySearchRequest,
        using client: any JourneySearching
    ) async throws -> Self {
        let origin = try await resolveStation(named: request.originName, selected: request.originPlace, using: client)
        try Task.checkCancellation()
        let destination = try await resolveStation(named: request.destinationName, selected: request.destinationPlace, using: client)
        try Task.checkCancellation()
        let departure = TicketJourneySearchPrefill.departureDate(
            request.departureTime, timeZoneIdentifier: origin?.timeZoneIdentifier
        )
        let hasExplicitTime = request.departureTime.map { $0.contains("T") } ?? false
        return Self(
            origin: origin,
            destination: destination,
            departureTime: departure,
            directReview: request.prefersDirectReview && hasExplicitTime
                ? ImportedJourneyAutoSelection(
                    trainNumber: request.trainNumber, departure: departure,
                    origin: origin, destination: destination
                )
                : nil
        )
    }

    @MainActor
    private static func resolveStation(
        named name: String, selected: RailPlace?, using client: any JourneySearching
    ) async throws -> RailPlace? {
        if let selected = TicketJourneySearchRequest.recognizedStation(selected, named: name) {
            return selected
        }
        let query = ImportedStationAlias.lookupQuery(for: name) ?? name
        let places = try await client.searchPlaces(query: query, limit: 10)
        try Task.checkCancellation()
        return TicketJourneySearchPrefill.bestPlace(named: name, from: places)
    }
}
