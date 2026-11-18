import SwiftUI
import TrainTrackerCore

struct ActiveTripCardPresentation {
    let trip: TrainTrip
    let status: TripPresentationStatus
    let routeTimeZones: JourneyPlanRouteTimeZones?
    let referenceDate: Date
    let lastSuccessfulCheck: Date?
    let lastRefreshFailed: Bool
    /// The passenger's saved leg of this train, when it belongs to a journey. Before departure
    /// from the boarding station the card guides to that station, not the train's next stop,
    /// which may be far up the line for a mid-route boarding.
    let selectedSegment: JourneyPlanSegment?
    /// One timetable context owns the card's route, next stop and boarding/ended guidance.
    /// Provider passage flags do not prove that this passenger boarded or arrived.
    let effectiveProgress: RailJourneyProgress
    let passengerProgress: RailJourneyProgress?

    init(
        trip: TrainTrip,
        routeTimeZones: JourneyPlanRouteTimeZones? = nil,
        referenceDate: Date = .now,
        lastSuccessfulCheck: Date? = nil,
        lastRefreshFailed: Bool = false,
        selectedSegment: JourneyPlanSegment? = nil
    ) {
        self.selectedSegment = selectedSegment
        self.trip = trip
        self.routeTimeZones = routeTimeZones
        self.referenceDate = referenceDate
        self.lastSuccessfulCheck = lastSuccessfulCheck
        self.lastRefreshFailed = lastRefreshFailed
        let selectedProgress = selectedSegment.map {
            RailJourneyProgress(
                trip: trip, referenceDate: referenceDate,
                boardingPlace: $0.from, alightingPlace: $0.to
            )
        }
        let usableSelectedProgress = selectedProgress.flatMap { $0.phase == .unavailable ? nil : $0 }
        passengerProgress = usableSelectedProgress
        let progress = usableSelectedProgress ?? RailJourneyProgress(trip: trip, referenceDate: referenceDate)
        effectiveProgress = progress
        status = TripPresentationStatus(trip: trip, referenceDate: referenceDate, progress: progress)
    }

    var serviceKicker: String {
        let product = trip.product.trimmingCharacters(in: .whitespacesAndNewlines)
        let operatorName = trip.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [operatorName]

        if !product.localizedCaseInsensitiveContains(operatorName) {
            parts.append(product)
        }

        parts.append(serviceStateDetail)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var routeTitle: String {
        "\(originName) → \(destinationName)"
    }

    var originName: String {
        trip.origin?.displayName ?? "Origin"
    }

    var destinationName: String {
        trip.destination?.displayName ?? trip.headsign
    }

    var originCode: String? {
        stationCode(trip.origin)
    }

    var destinationCode: String? {
        stationCode(trip.destination)
    }

    var destinationCountryCode: String? {
        trip.destination?.countryCode
    }

    /// Before departure, the relevant station is the selected boarding call or train origin.
    var isBeforeBoarding: Bool {
        let phase = effectiveProgress.phase
        return phase == .upcoming || phase == .departureSoon
    }

    /// The stop the card talks about: the boarding stop before boarding, then the next stop of
    /// the passenger's leg; the train's next stop for a standalone train.
    var guidanceStop: StopTime? {
        guard effectiveProgress.phase == .unavailable else { return effectiveProgress.focusStop }
        // A source with insufficient timetable data can still name its next call. Cancellation
        // never implies that another station became a valid boarding or alighting target.
        return trip.isCancelled ? nil : trip.nextStop
    }

    var nextStopLabel: String {
        isBeforeBoarding ? "Board at" : effectiveProgress.nextStopRole
    }

    var nextStopValue: String {
        if effectiveProgress.phase == .ended {
            return effectiveProgress.evidence.isArrivalConfirmed ? RunningStatusWords.arrived : RunningStatusWords.arrivalUnconfirmed
        }
        if trip.isCancelled { return RunningStatusWords.canceled }
        return guidanceStop?.station.displayName ?? "Unavailable"
    }

    var freshnessValue: String {
        guard let lastSuccessfulCheck else {
            return lastRefreshFailed ? "Check failed" : "Not yet"
        }
        let age = max(0, referenceDate.timeIntervalSince(lastSuccessfulCheck))
        let ageText: String
        if age < 60 {
            ageText = "Just now"
        } else if age < 3_600 {
            ageText = "\(max(1, Int(age / 60)))m ago"
        } else {
            ageText = "\(Int(age / 3_600))h ago"
        }
        return lastRefreshFailed ? "\(ageText) · Retry failed" : ageText
    }

    var freshnessColor: Color {
        lastRefreshFailed ? .ttStatusDelayed : .ttTextSecondary
    }

    var departureDate: Date? {
        guard let origin = trip.stopTimes.first else { return nil }
        return origin.expectedDeparture
            ?? origin.scheduledDeparture
            ?? origin.expectedArrival
            ?? origin.scheduledArrival
    }

    var arrivalDate: Date? {
        guard !trip.isCancelled, let destination = trip.stopTimes.last else { return nil }
        return destination.expectedArrival
            ?? destination.scheduledArrival
            ?? destination.expectedDeparture
            ?? destination.scheduledDeparture
    }

    var departureTimeText: String? {
        guard let departureDate, let routeTimeZones else { return nil }
        return JourneyPlanDateTimePresentation.time(
            departureDate,
            timeZoneIdentifier: routeTimeZones.departureTimeZoneIdentifier
        )
    }

    var arrivalTimeText: String? {
        guard let arrivalDate, let routeTimeZones else { return nil }
        return JourneyPlanDateTimePresentation.time(
            arrivalDate,
            timeZoneIdentifier: routeTimeZones.arrivalTimeZoneIdentifier
        )
    }

    var platformText: String {
        guidanceStop?.platformSummary(at: referenceDate) ?? platformGuidance.summaryText
    }

    var platformLabel: String {
        guidanceStop?.platformNoun ?? "Platform"
    }

    var platformValue: String {
        platformGuidance.metricValue
    }

    var platformValueColor: Color {
        if platformGuidance.isOfficialChange { return .ttStatusDelayed }
        return platformGuidance.isPredicted ? .ttActionLive : .ttTextPrimary
    }

    var stopCountText: String {
        "\(trip.stopTimes.count) \(trip.stopTimes.count == 1 ? "stop" : "stops")"
    }

    var detailStatusText: String {
        switch status.kind {
        case .scheduled:
            return "Timetable times only"
        case .cancelled, .delayed, .arrived, .onTime, .estimated, .unavailable:
            return status.text
        }
    }

    var detailStatusLabel: String {
        switch status.kind {
        case .delayed: "Delay"
        case .cancelled, .arrived, .onTime, .scheduled, .estimated, .unavailable: "Status"
        }
    }

    var detailStatusValue: String {
        switch status.kind {
        case .cancelled, .delayed, .arrived, .onTime, .scheduled, .estimated: status.text
        case .unavailable: "Unavailable"
        }
    }

    var detailStatusColor: Color {
        status.kind.isDisruption ? status.color : .ttTextSecondary
    }

    var updateKey: String {
        let expected = guidanceStop?.expectedArrival ?? guidanceStop?.expectedDeparture
        return "\(trip.id.rawValue)|\(expected?.timeIntervalSinceReferenceDate ?? 0)|\(platformGuidance.summaryText)"
    }

    private var serviceStateDetail: String {
        switch status.kind {
        case .onTime, .scheduled:
            return scheduledDurationText ?? status.text
        case .delayed, .cancelled, .arrived, .estimated, .unavailable:
            return status.text
        }
    }

    private var platformGuidance: PlatformGuidance {
        guidanceStop?.platformGuidance(at: referenceDate) ?? .unavailable
    }

    private var scheduledDurationText: String? {
        guard let origin = trip.stopTimes.first,
              let destination = trip.stopTimes.last,
              let start = origin.scheduledDeparture ?? origin.scheduledArrival,
              let end = destination.scheduledArrival ?? destination.scheduledDeparture
        else {
            return nil
        }

        let totalMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 {
            return "\(minutes) min"
        }
        return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)"
    }

    private func stationCode(_ station: Station?) -> String? {
        StationShortCode.code(for: station)
    }
}


extension RailJourneyProgress {
    /// A clock can suggest which stop comes next without placing the train there.
    var nextStopRole: String {
        guard phase == .underway, let stop = focusStop, evidence.observedFocusStopID != stop.id else { return "Next stop" }
        return stop.expectedArrival == nil && stop.expectedDeparture == nil ? "Next scheduled stop" : "Next estimated stop"
    }
}
