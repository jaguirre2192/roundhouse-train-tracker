import Foundation
import TrainTrackerCore

struct JourneyPlanRouteTimeZones: Equatable {
    let departureTimeZoneIdentifier: String
    let arrivalTimeZoneIdentifier: String
}

struct JourneyPlanChildPresentation: Identifiable {
    enum Status: Equatable {
        case tracked
        case missing
    }

    let tripID: RailIdentifier
    let trip: TrainTrip?

    var id: RailIdentifier { tripID }
    var status: Status { trip == nil ? .missing : .tracked }
    var statusText: String {
        trip == nil ? JourneySearchCopy.Plan.noLongerTracked : JourneySearchCopy.Plan.tracked
    }
}

struct JourneyPlanDirectionPresentation: Identifiable {
    let title: String
    let routeTitle: String
    let departure: Date
    let arrival: Date
    let departureDateText: String
    let departureTimeText: String
    let arrivalDateText: String
    let arrivalTimeText: String
    let departureTimeZoneIdentifier: String
    let arrivalTimeZoneIdentifier: String
    let children: [JourneyPlanChildPresentation]

    var id: String { title }
    var routeTimeZones: JourneyPlanRouteTimeZones {
        JourneyPlanRouteTimeZones(
            departureTimeZoneIdentifier: departureTimeZoneIdentifier,
            arrivalTimeZoneIdentifier: arrivalTimeZoneIdentifier
        )
    }
}

struct JourneyPlanPresentation: Identifiable {
    let plan: TrackedJourneyPlan
    let directions: [JourneyPlanDirectionPresentation]
    let nextActionableTrip: TrainTrip?
    let nextActionableDirectionTitle: String?
    let nextActionableDateText: String?
    let nextActionableTimeText: String?
    let nextActionableTimeZoneIdentifier: String?
    let childCount: Int
    let effectiveArrival: Date
    let currentDirectionDeparture: Date
    let hasObservedUnfinishedJourney: Bool

    var id: UUID { plan.id }
    var routeTitle: String { "\(plan.origin.displayName) → \(plan.destination.displayName)" }
    var outboundDate: Date { plan.outbound.departure }
    var returnDate: Date? { plan.returnDirection?.departure }
    var outboundDateText: String { directions[0].departureDateText }
    var returnDateText: String? { directions.count > 1 ? directions[1].departureDateText : nil }
    var childCountText: String { JourneySearchCopy.Plan.childCount(childCount) }

    init(plan: TrackedJourneyPlan, trips: [TrainTrip], at date: Date = .now) {
        self.plan = plan
        let savedDirections = [plan.outbound] + (plan.returnDirection.map { [$0] } ?? [])
        effectiveArrival = savedDirections.map {
            JourneyHomeGuidance.effectiveArrival(for: $0, trips: trips, at: date)
        }.max() ?? plan.outbound.arrival
        let stage = JourneyPlanStage(plan: plan, trips: trips, referenceDate: date)
        currentDirectionDeparture = stage.direction.departure
        hasObservedUnfinishedJourney = stage.hasObservedUnfinishedJourney
        let tripsByID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
        var presentations = [Self.direction(
            title: JourneySearchCopy.outbound,
            routeTitle: "\(plan.origin.displayName) → \(plan.destination.displayName)",
            direction: plan.outbound,
            departureTimeZoneIdentifier: plan.origin.timeZoneIdentifier,
            arrivalTimeZoneIdentifier: plan.destination.timeZoneIdentifier,
            tripsByID: tripsByID
        )]
        if let returnDirection = plan.returnDirection {
            presentations.append(Self.direction(
                title: JourneySearchCopy.returnDirection,
                routeTitle: "\(plan.destination.displayName) → \(plan.origin.displayName)",
                direction: returnDirection,
                departureTimeZoneIdentifier: plan.destination.timeZoneIdentifier,
                arrivalTimeZoneIdentifier: plan.origin.timeZoneIdentifier,
                tripsByID: tripsByID
            ))
        }
        directions = presentations

        var seen: Set<RailIdentifier> = []
        let children = presentations
            .flatMap(\.children)
            .filter { seen.insert($0.tripID).inserted }
        childCount = children.count
        let candidates = presentations.flatMap { direction in
            direction.children.compactMap { child in
                child.trip.map { (trip: $0, direction: direction) }
            }
        }
        let preferredTrip = TripAutomaticRefreshPolicy.preferredActiveTrip(
            in: candidates.map(\.trip),
            at: date
        )
        let nextActionable = preferredTrip.flatMap { preferred in
            candidates.first { $0.trip.id == preferred.id }
        }
        nextActionableTrip = nextActionable?.trip
        nextActionableDirectionTitle = nextActionable?.direction.title
        nextActionableTimeZoneIdentifier = nextActionable?.direction.departureTimeZoneIdentifier
        if let nextActionable,
           let nextDeparture = nextActionable.trip.stopTimes.lazy.compactMap(\.scheduledDeparture).first {
            nextActionableDateText = JourneyPlanDateTimePresentation.date(
                nextDeparture,
                timeZoneIdentifier: nextActionable.direction.departureTimeZoneIdentifier
            )
            nextActionableTimeText = JourneyPlanDateTimePresentation.labeledTime(
                nextDeparture,
                timeZoneIdentifier: nextActionable.direction.departureTimeZoneIdentifier
            )
        } else {
            nextActionableDateText = nil
            nextActionableTimeText = nil
        }
    }

    private static func direction(
        title: String,
        routeTitle: String,
        direction: JourneyPlanDirection,
        departureTimeZoneIdentifier: String,
        arrivalTimeZoneIdentifier: String,
        tripsByID: [RailIdentifier: TrainTrip]
    ) -> JourneyPlanDirectionPresentation {
        JourneyPlanDirectionPresentation(
            title: title,
            routeTitle: routeTitle,
            departure: direction.departure,
            arrival: direction.arrival,
            departureDateText: JourneyPlanDateTimePresentation.date(
                direction.departure,
                timeZoneIdentifier: departureTimeZoneIdentifier
            ),
            departureTimeText: JourneyPlanDateTimePresentation.labeledTime(
                direction.departure,
                timeZoneIdentifier: departureTimeZoneIdentifier
            ),
            arrivalDateText: JourneyPlanDateTimePresentation.date(
                direction.arrival,
                timeZoneIdentifier: arrivalTimeZoneIdentifier
            ),
            arrivalTimeText: JourneyPlanDateTimePresentation.labeledTime(
                direction.arrival,
                timeZoneIdentifier: arrivalTimeZoneIdentifier
            ),
            departureTimeZoneIdentifier: departureTimeZoneIdentifier,
            arrivalTimeZoneIdentifier: arrivalTimeZoneIdentifier,
            children: direction.childTripIDs.map {
                JourneyPlanChildPresentation(tripID: $0, trip: tripsByID[$0])
            }
        )
    }
}

struct JourneyPlanListPresentation {
    let journeyPlans: [JourneyPlanPresentation]
    let activeTrip: TrainTrip?
    let activeTripRouteTimeZones: JourneyPlanRouteTimeZones?
    let individualTrips: [TrainTrip]

    init(
        plans: [TrackedJourneyPlan],
        trips: [TrainTrip],
        activeTrip: TrainTrip?,
        at date: Date = .now
    ) {
        let journeyPlans = plans
            .map { JourneyPlanPresentation(plan: $0, trips: trips, at: date) }
            .sorted { $0.outboundDate < $1.outboundDate }
        self.journeyPlans = journeyPlans
        let groupedIDs = Set(
            plans.flatMap {
                $0.outbound.childTripIDs + ($0.returnDirection?.childTripIDs ?? [])
            }
        )
        // Refresh may retain an ended train as a recovery candidate. It belongs in history,
        // so filter it before suppressing the highlighted train from the individual lists.
        let highlightedTrip = activeTrip.flatMap { trip -> TrainTrip? in
            // Saved plans own their passenger bounds and presentation. A child train can
            // continue beyond alighting after its plan has correctly moved to history.
            guard !groupedIDs.contains(trip.id) else { return nil }
            let phase = RailJourneyProgress(trip: trip, referenceDate: date).phase
            return phase == .underway || phase == .upcoming || phase == .departureSoon ? trip : nil
        }
        self.activeTrip = highlightedTrip
        activeTripRouteTimeZones = highlightedTrip.flatMap { activeTrip in
            journeyPlans
                .flatMap(\.directions)
                .first { direction in
                    direction.children.contains { $0.tripID == activeTrip.id }
                }?
                .routeTimeZones
        }

        individualTrips = trips.filter {
            $0.id != highlightedTrip?.id && !groupedIDs.contains($0.id)
        }
    }

    func upcomingTrains(asOf date: Date) -> [TrainTrip] {
        classifiedTrains(asOf: date)
            .filter { $0.progress.phase == .upcoming || $0.progress.phase == .departureSoon }
            .sorted { ($0.progress.departureDate ?? .distantFuture) < ($1.progress.departureDate ?? .distantFuture) }
            .map(\.trip)
    }

    func currentTrains(asOf date: Date) -> [TrainTrip] {
        classifiedTrains(asOf: date)
            .filter { $0.progress.phase == .underway }
            .sorted { ($0.progress.arrivalDate ?? .distantFuture) < ($1.progress.arrivalDate ?? .distantFuture) }
            .map(\.trip)
    }

    func pastTrains(asOf date: Date) -> [TrainTrip] {
        classifiedTrains(asOf: date)
            .filter { $0.progress.phase == .ended }
            .sorted { ($0.progress.arrivalDate ?? .distantPast) > ($1.progress.arrivalDate ?? .distantPast) }
            .map(\.trip)
    }

    func otherTrains(asOf date: Date) -> [TrainTrip] {
        classifiedTrains(asOf: date).filter { $0.progress.phase == .unavailable }.map(\.trip)
    }

    func currentJourneys(asOf date: Date) -> [JourneyPlanPresentation] {
        journeyPlans.filter { ($0.effectiveArrival > date || $0.hasObservedUnfinishedJourney) && $0.currentDirectionDeparture <= date }
    }

    func upcomingJourneys(asOf date: Date) -> [JourneyPlanPresentation] {
        journeyPlans.filter { $0.effectiveArrival > date && $0.currentDirectionDeparture > date }
            .sorted { $0.currentDirectionDeparture < $1.currentDirectionDeparture }
    }

    func pastJourneys(asOf date: Date) -> [JourneyPlanPresentation] {
        journeyPlans
            .filter { $0.effectiveArrival <= date && !$0.hasObservedUnfinishedJourney }
            .sorted { $0.effectiveArrival > $1.effectiveArrival }
    }

    private func classifiedTrains(asOf date: Date) -> [(trip: TrainTrip, progress: RailJourneyProgress)] {
        individualTrips.map { (trip: $0, progress: RailJourneyProgress(trip: $0, referenceDate: date)) }
    }
}

struct JourneyPlanRemovalPresentation {
    struct Child: Identifiable, Equatable {
        enum Reason: Equatable {
            case removable
            case shared
            case preExisting
            case sharedAndPreExisting
            case missing
        }

        let id: RailIdentifier
        let reason: Reason

        var reasonText: String {
            switch reason {
            case .removable: JourneySearchCopy.Plan.willStopTracking
            case .shared: JourneySearchCopy.Plan.shared
            case .preExisting: JourneySearchCopy.Plan.preExisting
            case .sharedAndPreExisting: JourneySearchCopy.Plan.sharedAndPreExisting
            case .missing: JourneySearchCopy.Plan.noLongerTracked
            }
        }
    }

    let removableChildren: [Child]
    let preservedChildren: [Child]
    let missingChildren: [Child]

    var hasTrackedTrainsToRemove: Bool { !removableChildren.isEmpty }
    var actionTitle: String {
        guard hasTrackedTrainsToRemove else { return JourneySearchCopy.Plan.removeGroup }
        return JourneySearchCopy.Plan.stopTrackingCount(removableChildren.count)
    }
    var warningMessage: String {
        if hasTrackedTrainsToRemove {
            return JourneySearchCopy.Plan.removeWithTrainsWarning
        }
        return JourneySearchCopy.Plan.removeGroupWarning
    }

    init(preview: JourneyPlanRemovalPreview, trips: [TrainTrip]) {
        let trackedIDs = Set(trips.map(\.id))
        removableChildren = preview.removableChildTripIDs.filter(trackedIDs.contains).map {
            Child(id: $0, reason: .removable)
        }
        let shared = Set(preview.sharedChildTripIDs)
        let preExisting = Set(preview.preExistingChildTripIDs)
        preservedChildren = preview.preservedChildTripIDs.filter(trackedIDs.contains).map { id in
            let reason: Child.Reason
            if shared.contains(id), preExisting.contains(id) {
                reason = .sharedAndPreExisting
            } else if shared.contains(id) {
                reason = .shared
            } else {
                reason = .preExisting
            }
            return Child(id: id, reason: reason)
        }
        var seenMissing: Set<RailIdentifier> = []
        missingChildren = (preview.removableChildTripIDs + preview.preservedChildTripIDs)
            .filter { !trackedIDs.contains($0) && seenMissing.insert($0).inserted }
            .map { Child(id: $0, reason: .missing) }
    }
}
