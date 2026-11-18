import Foundation
import TrainTrackerCore

struct ImportedJourneyPrefill {
    let origin: RailPlace?
    let destination: RailPlace?
    let departureTime: Date?
    let directReview: ImportedJourneyAutoSelection?
    let calendarSource: CalendarJourneySource?

    @MainActor
    static func resolve(
        _ request: TicketJourneySearchRequest,
        using client: any JourneySearching
    ) async throws -> Self {
        let origin = try await resolveStation(named: request.originName, selected: request.originPlace, using: client)
        try Task.checkCancellation()
        let destination = try await resolveStation(named: request.destinationName, selected: request.destinationPlace, using: client)
        try Task.checkCancellation()
        let departure: Date?
        if request.localCalendarTiming != nil {
            // EventKit supplied a civil time. Resolve it only once we know the boarding station.
            let zone = origin.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) }
            let clock = request.departureTime.flatMap(TicketWallClock.init(requestValue:))
            departure = zone.flatMap { zone in clock?.exactTime(in: zone) }
        } else {
            departure = TicketJourneySearchPrefill.departureDate(
                request.departureTime, timeZoneIdentifier: origin?.timeZoneIdentifier
            )
        }
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
                : nil,
            calendarSource: reviewedSource(for: request, origin: origin, departure: departure)
        )
    }

    private static func reviewedSource(
        for request: TicketJourneySearchRequest, origin: RailPlace?, departure: Date?
    ) -> CalendarJourneySource? {
        guard let source = request.calendarSource, let timing = request.localCalendarTiming,
              let origin, let departure else { return request.calendarSource }
        return CalendarJourneySource(eventKey: source.eventKey, revision: source.revision, details: CalendarJourneyDetails(
            originName: request.originName, destinationName: request.destinationName, trainNumber: request.trainNumber,
            departureDate: departure, timeZoneIdentifier: timing.eventTimeZoneIdentifier,
            isAllDay: timing.isAllDay, boardingTimeZoneIdentifier: origin.timeZoneIdentifier
        ))
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
