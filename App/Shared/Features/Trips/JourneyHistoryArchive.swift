import Foundation
import TrainTrackerCore

/// A chronological index of the rider's saved bookings. The regular My Trips classification
/// still decides when a train or a passenger's selected journey belongs in history.
struct JourneyHistoryArchive {
    struct Month: Identifiable {
        let id: Int
        let title: String
        let tickets: [JourneyHistoryTicket]
    }

    struct MonthRow: Identifiable {
        let first: Month
        let second: Month?
        var id: Int { first.id }
    }

    /// On two-column displays, consecutive months with just one ticket share a row. Sections
    /// with two or more tickets retain their own heading across both columns.
    static func rows(_ months: [Month], pairsSingles: Bool) -> [MonthRow] {
        var rows: [MonthRow] = []
        var index = months.startIndex
        while index < months.endIndex {
            let first = months[index]
            index += 1
            if pairsSingles, first.tickets.count == 1, index < months.endIndex, months[index].tickets.count == 1 {
                rows.append(MonthRow(first: first, second: months[index]))
                index += 1
            } else {
                rows.append(MonthRow(first: first, second: nil))
            }
        }
        return rows
    }

    let months: [Month]
    let watched: [JourneyHistoryTicket]
    private let latestTicketID: String?

    init(plans: [TrackedJourneyPlan], trips: [TrainTrip], at date: Date) {
        self.init(selection: JourneyHistorySelection(plans: plans, trips: trips, at: date), plans: plans)
    }

    init(selection: JourneyHistorySelection, plans: [TrackedJourneyPlan], watching: Set<RailIdentifier> = []) {
        let journeys = selection.journeys.map { journey in
            (JourneyHistoryTicket(journey: journey), Self.isWatchOnly(journey.plan, watching: watching))
        }
        let trains = selection.trains.map { (JourneyHistoryTicket(trip: $0, plans: plans), watching.contains($0.id)) }
        let all = (journeys + trains).sorted { lhs, rhs in
            if lhs.0.departure == rhs.0.departure { return lhs.0.id < rhs.0.id }
            return lhs.0.departure > rhs.0.departure
        }
        watched = all.compactMap { $0.1 ? $0.0 : nil }
        let newestFirst = all.compactMap { $0.1 ? nil : $0.0 }
        latestTicketID = newestFirst.first?.id
        months = Dictionary(grouping: newestFirst, by: \.departureMonth).map { key, tickets in
            Month(id: key, title: tickets[0].monthTitle, tickets: tickets)
        }.sorted { $0.id > $1.id }
    }

    static func isWatchOnly(_ plan: TrackedJourneyPlan, watching: Set<RailIdentifier>) -> Bool {
        let ids = plan.outbound.childTripIDs + (plan.returnDirection?.childTripIDs ?? [])
        return !ids.isEmpty && ids.allSatisfy(watching.contains)
    }

    func featuredTicketID(matching query: String) -> String? {
        Self.searchWords(query).isEmpty ? latestTicketID : nil
    }

    func months(matching query: String) -> [Month] {
        let terms = Self.searchTerms(query)
        guard !terms.isEmpty else { return months }
        return months.compactMap { month in
            let tickets = month.tickets.filter { ticket in
                terms.allSatisfy { ticket.searchText.contains($0) }
            }
            return tickets.isEmpty ? nil : Month(id: month.id, title: month.title, tickets: tickets)
        }
    }

    func watched(matching query: String) -> [JourneyHistoryTicket] {
        let terms = Self.searchTerms(query)
        return watched.filter { ticket in terms.allSatisfy { ticket.searchText.contains($0) } }
    }

    private static func searchTerms(_ query: String) -> [Substring] {
        let words = searchWords(query).split(separator: " ")
        return words.enumerated().compactMap { index, word in
            if words.count >= 3 && (index == 0 && word == "from" || index > 0 && index < words.count - 1 && word == "to") { return nil }
            return word
        }
    }

    /// The same normalization on both sides lets "Aeroport", "Kings Cross", and a pasted route
    /// with an arrow find their printed names without requiring the rider's keyboard to match.
    static func searchWords(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0 != "'" && $0 != "’" }
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

/// Eligibility changes when the library changes or a train can enter history. A late train
/// kept active by fresh observations is checked again while that evidence remains relevant.
struct JourneyHistorySelection {
    let journeys: [JourneyPlanPresentation]
    let trains: [TrainTrip]
    let routes: Set<TripsRoute>
    let nextCheck: Date?

    init(plans: [TrackedJourneyPlan], trips: [TrainTrip], at date: Date) {
        let library = JourneyPlanListPresentation(plans: plans, trips: trips, activeTrip: nil, at: date)
        let pastJourneys = library.pastJourneys(asOf: date)
        let pastTrains = library.pastTrains(asOf: date)
        let saved = Set(pastJourneys.map { TripsRoute.journey($0.id) } + pastTrains.map { TripsRoute.train($0.id) })
        var boundaries = library.journeyPlans.compactMap { plan -> Date? in
            guard !saved.contains(.journey(plan.id)) else { return nil }
            return plan.effectiveArrival > date ? plan.effectiveArrival : date.addingTimeInterval(30)
        }
        for trip in library.individualTrips where !saved.contains(.train(trip.id)) {
            let progress = RailJourneyProgress(trip: trip, referenceDate: date)
            guard progress.phase != .unavailable, progress.phase != .ended else { continue }
            let possibleEnd = progress.evidence.isArrivalConfirmed ? progress.departureDate : progress.arrivalDate
            if let possibleEnd, possibleEnd > date {
                boundaries.append(possibleEnd)
            } else {
                // A fresh observation may keep the train en route beyond its expected arrival.
                // Some providers report a stop passage without a position expiry.
                let recheck = progress.nextTransitionDate?.addingTimeInterval(1) ?? date.addingTimeInterval(30)
                boundaries.append(max(recheck, date.addingTimeInterval(1)))
            }
        }
        journeys = pastJourneys
        trains = pastTrains
        routes = saved
        nextCheck = boundaries.min()
    }
}

struct JourneyHistoryTicket: Identifiable {
    let id: String
    let route: TripsRoute
    let origin: String
    let destination: String
    let cityScope: String?
    let departure: Date
    let zone: TimeZone
    let timeText: String?
    let service: String
    let routeTrace: JourneyHistoryRouteTrace?
    let disruption: TripPresentationStatus?
    let searchText: String

    init(journey: JourneyPlanPresentation) {
        let plan = journey.plan
        let outward = plan.outbound.selectedSegments ?? []
        let from = outward.first?.from ?? plan.origin
        let to = outward.last?.to ?? plan.destination
        let boardingZone = TimeZone(identifier: from.timeZoneIdentifier) ?? TimeZone(identifier: plan.origin.timeZoneIdentifier)
        id = "pastJourney-\(plan.id.uuidString)"
        route = .journey(plan.id)
        origin = TicketStubCardContent.endpointTitle(for: from)
        destination = TicketStubCardContent.endpointTitle(for: to)
        switch (from.kind == .city, to.kind == .city) {
        case (true, true): cityScope = String(localized: "All stations in both cities")
        case (true, false): cityScope = String(localized: "All stations in \(origin)")
        case (false, true): cityScope = String(localized: "All stations in \(destination)")
        case (false, false): cityScope = nil
        }
        departure = plan.outbound.departure
        zone = boardingZone ?? .gmt
        timeText = Self.time(departure, in: boardingZone)
        disruption = nil

        let directions = [plan.outbound] + (plan.returnDirection.map { [$0] } ?? [])
        let children = journey.directions.flatMap(\.children).compactMap(\.trip)
        let outwardService = outward.first { $0.kind == .rail }?.serviceName
            ?? journey.directions.first?.children.compactMap(\.trip).first.map(LiveLineTicketPresentation.operatorLine(for:))
        let railLegCount = directions.reduce(0) { count, direction in
            count + (direction.selectedSegments?.filter { $0.kind == .rail }.count ?? direction.childTripIDs.count)
        }
        let countText = railLegCount > 0 ? JourneySearchCopy.Plan.childCount(railLegCount) : nil
        let rail = outward.filter { $0.kind == .rail }
        if plan.returnDirection != nil {
            service = [String(localized: "Round trip"), countText].compactMap { $0 }.joined(separator: " · ")
        } else if rail.count > 1, let interchange = rail.first?.to,
                  interchange.id != from.id && interchange.id != to.id {
            service = String(localized: "Via \(TicketStubCardContent.endpointTitle(for: interchange))")
        } else if railLegCount == 1, let outwardService, !outwardService.isEmpty {
            service = outwardService
        } else {
            service = countText ?? String(localized: "One-way journey")
        }

        // Include only the passenger's bounded stops on a saved booking. Its underlying train
        // can run for hours before boarding or after alighting and is a separate archive fact.
        var words = [origin, destination, plan.origin.displayName, plan.destination.displayName, service]
        words += children.flatMap { [$0.product, $0.operatorName] }
        var outwardLegs: [[GeoCoordinate]] = []
        var firstCode: String?
        var lastCode: String?
        for (directionIndex, direction) in directions.enumerated() {
            for (index, segment) in (direction.selectedSegments ?? []).enumerated() {
                words += [segment.from.displayName, segment.to.displayName, segment.serviceName ?? ""]
                let matched = children.first { $0.id == segment.resolvedTripID }.map {
                    RailJourneyProgress(trip: $0, referenceDate: plan.outbound.departure,
                                        boardingPlace: segment.from, alightingPlace: segment.to).stops
                } ?? []
                words += Self.stationWords(matched)
                if directionIndex == 0 {
                    let start = Self.location(segment.from, matched: matched.first)
                    let end = Self.location(segment.to, matched: matched.last)
                    outwardLegs.append([start] + matched.dropFirst().dropLast().map(\.station.location) + [end])
                    if index == 0 { firstCode = StationShortCode.code(for: matched.first?.station) }
                    if index == outward.count - 1 { lastCode = StationShortCode.code(for: matched.last?.station) }
                }
            }
        }
        if outward.isEmpty { outwardLegs = [[from.location, to.location]] }
        routeTrace = JourneyHistoryRouteTrace(legs: outwardLegs, originCode: firstCode, destinationCode: lastCode)
        searchText = JourneyHistoryArchive.searchWords(words.joined(separator: " "))
    }

    init(trip: TrainTrip, plans: [TrackedJourneyPlan]) {
        let stop = trip.stopTimes.first
        let clock = stop?.scheduledDeparture ?? stop?.expectedDeparture
        let timedDeparture = clock.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
        let context = TripDetailTimeZoneContext(trip: trip, plans: plans)
        let boardingZone = stop.flatMap { context.timeZoneIdentifier(for: $0) }.flatMap(TimeZone.init(identifier:))
            ?? StationTimeZoneResolver.cached(for: trip.origin?.id)
        id = "individualTrain-\(trip.id.rawValue)"
        route = .train(trip.id)
        origin = trip.origin?.displayName ?? String(localized: "Origin")
        destination = trip.destination?.displayName ?? trip.headsign
        cityScope = nil
        departure = timedDeparture ?? trip.serviceDate
        // A provider service day is stored at UTC midnight. It is a calendar date, never a
        // midnight departure to be shifted back a day in a western boarding zone.
        zone = timedDeparture == nil ? .gmt : (boardingZone ?? .gmt)
        timeText = timedDeparture.map { Self.time($0, in: boardingZone) }
        service = LiveLineTicketPresentation.operatorLine(for: trip)
        routeTrace = JourneyHistoryRouteTrace(legs: [trip.stopTimes.map(\.station.location)],
                                              originCode: StationShortCode.code(for: trip.origin),
                                              destinationCode: StationShortCode.code(for: trip.destination))
        let status = TripPresentationStatus(trip: trip)
        disruption = status.kind.isDisruption ? status : nil
        let words = [origin, destination, service, trip.headsign] + Self.stationWords(trip.stopTimes)
        searchText = JourneyHistoryArchive.searchWords(words.joined(separator: " "))
    }

    var departureMonth: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month], from: departure)
        return (components.year ?? 0) * 100 + (components.month ?? 0)
    }

    var monthTitle: String { departure.formatted(dateStyle.month(.wide).year()) }
    var weekday: String { departure.formatted(dateStyle.weekday(.abbreviated)) }
    var day: String { departure.formatted(dateStyle.day()) }
    var fullDate: String { departure.formatted(dateStyle.weekday(.wide).month(.wide).day().year()) }

    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(calendar: Calendar(identifier: .gregorian), timeZone: zone)
    }

    private static func time(_ date: Date, in zone: TimeZone?) -> String {
        guard let zone else {
            return JourneyPlanDateTimePresentation.time(date, timeZoneIdentifier: TimeZone.gmt.identifier) + " UTC"
        }
        return JourneyPlanDateTimePresentation.labeledTime(date, timeZoneIdentifier: zone.identifier)
    }

    private static func location(_ place: RailPlace, matched: StopTime?) -> GeoCoordinate {
        if JourneyHistoryRouteTrace.valid(place.location) { return place.location }
        return matched?.station.location ?? place.location
    }

    private static func stationWords(_ stops: [StopTime]) -> [String] {
        stops.flatMap { $0.station.names.map(\.value) + $0.station.codes.values }
    }
}
