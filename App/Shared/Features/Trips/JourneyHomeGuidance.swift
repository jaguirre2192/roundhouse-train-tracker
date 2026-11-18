import Foundation
import TrainTrackerCore

/// Home context follows saved passenger endpoints and provider timing, never location.
struct JourneyHomeGuidance {
    let plan: TrackedJourneyPlan
    let stage: JourneyPlanStage
    let endDate: Date
    let referenceDate: Date

    var isRecentCompletion: Bool { referenceDate >= endDate && !stage.hasObservedUnfinishedJourney }
    var isReturn: Bool { stage.directionTitle == JourneySearchCopy.returnDirection }
    var origin: RailPlace { isReturn ? plan.destination : plan.origin }
    var destination: RailPlace { isReturn ? plan.origin : plan.destination }

    /// Clock-based stage names say what the timetable indicates, not where the passenger is.
    var title: String {
        if isRecentCompletion { return isReturn ? "Return arrival time has passed" : "Arrival time has passed" }
        if stage.hasObservedUnfinishedJourney { return "Arrival not yet confirmed" }
        if stage.kind == .connection { return "Connection by timetable" }
        if referenceDate >= stage.direction.departure { return isReturn ? "Return underway by timetable" : "Underway by timetable" }
        let minutes = stage.direction.departure.timeIntervalSince(referenceDate) / 60
        if minutes <= 30 { return isReturn ? "Return departs soon" : "Departs soon" }
        return isReturn ? "Your return journey" : "Your next journey"
    }

    var completionText: String {
        if plan.returnDirection != nil, !isReturn {
            return "The last saved arrival time has passed. Your return journey will appear here before it departs."
        }
        return "The last saved arrival time has passed. Your journey and tickets remain available."
    }

    static func select(plans: [TrackedJourneyPlan], trips: [TrainTrip], at date: Date) -> Self? {
        let contexts = plans.map { plan in
            let stage = JourneyPlanStage(plan: plan, trips: trips, referenceDate: date)
            return Self(plan: plan, stage: stage,
                        endDate: effectiveArrival(for: stage.direction, trips: trips, at: date), referenceDate: date)
        }
        let current = contexts.filter { !$0.isRecentCompletion && $0.stage.direction.departure <= date }
            .sorted { $0.stage.direction.departure > $1.stage.direction.departure }
        if let first = current.first { return first }
        return contexts.filter { !$0.isRecentCompletion }
            .min { $0.stage.direction.departure < $1.stage.direction.departure }
    }

    /// Bound the journey to the selected passenger endpoints, including usable arrival estimates.
    /// A train continuing beyond the alighting station must not extend the passenger's journey.
    static func effectiveArrival(for direction: JourneyPlanDirection, trips: [TrainTrip], at date: Date) -> Date {
        let ends = (direction.selectedSegments ?? []).compactMap { segment -> Date? in
            guard let id = segment.resolvedTripID,
                  direction.childTripIDs.contains(id),
                  !direction.ambiguousTripIDs.contains(id),
                  segment.unavailableReason == nil,
                  trips.filter({ $0.id == id }).count == 1,
                  let trip = trips.first(where: { $0.id == id }) else { return segment.arrival }
            let progress = RailJourneyProgress(trip: trip, referenceDate: date,
                boardingPlace: segment.from, alightingPlace: segment.to)
            guard progress.phase != .unavailable, !progress.isCancelled,
                  progress.stops.first?.isCancelled == false,
                  progress.stops.last?.isCancelled == false else { return segment.arrival }
            return progress.arrivalDate ?? segment.arrival
        }
        return ends.reduce(direction.arrival, max)
    }

    static func arrivalText(_ presentation: JourneyExperiencePresentation) -> String? {
        guard !presentation.progress.isCancelled, !presentation.hasCancelledBoundary,
              let stop = presentation.progress.stops.last,
              let arrival = stop.expectedArrival ?? stop.scheduledArrival else { return nil }
        let hasEstimate = stop.expectedArrival != nil
        let label = hasEstimate ? (presentation.needsRefresh ? "Last arrival estimate" : "Estimated arrival") : "Timetable arrival"
        let time = JourneyExperienceClock.time(arrival, zone: presentation.timeZones.timeZoneIdentifier(for: stop))
        var value = "\(label) at \(presentation.destinationName): \(time)"
        if let expected = stop.expectedArrival, let scheduled = stop.scheduledArrival {
            let minutes = Int((expected.timeIntervalSince(scheduled) / 60).rounded())
            if let difference = RunningStatusWords.difference(minutes: minutes) { value += " · \(difference)" }
        }
        return value
    }

    static func connectionText(_ connection: JourneyPlanStage.Connection) -> String? {
        var parts: [String] = []
        if let minutes = connection.timetableMinutes { parts.append("Saved interval: \(minutes) min") }
        if let minutes = connection.estimatedMinutes { parts.append("Last estimated interval: \(minutes) min") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ". ") + ". This is time between trains, not confirmation that the connection is possible."
    }

    static func connectionRiskMessage(_ connection: JourneyPlanStage.Connection) -> String {
        let next = connection.next.serviceName ?? "your next train"
        let station = connection.next.from.displayName
        if !connection.isMissed, let minutes = connection.estimatedMinutes {
            let walk = connection.walkMinutes > 0 ? ", including a \(connection.walkMinutes) min walk" : ""
            return "The last arrival estimate leaves \(minutes) min to reach \(next) at \(station)\(walk). Check the operator’s travel advice."
        }
        return "The last arrival estimate leaves no time before \(next) departs from \(station). Check the operator’s travel advice."
    }

    static func alternatives(stage: JourneyPlanStage, at date: Date) -> TicketJourneySearchRequest? {
        // Start at the affected segment/connection, never the train's whole route.
        guard let segment = stage.connection?.next ?? stage.focusSegment else { return nil }
        let destination = stage.direction.selectedSegments?.last?.to ?? segment.to
        guard segment.from.id != destination.id else { return nil }
        return TicketJourneySearchRequest(originName: segment.from.displayName,
            destinationName: destination.displayName,
            departureTime: ISO8601DateFormatter().string(from: max(date, segment.departure ?? date)),
            trainNumber: nil)
    }

    static func directionsURL(to place: RailPlace) -> URL? {
        guard place.location.latitude != 0 || place.location.longitude != 0 else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: "\(place.location.latitude),\(place.location.longitude)"),
                                  URLQueryItem(name: "dirflg", value: "w")]
        return components?.url
    }
}
