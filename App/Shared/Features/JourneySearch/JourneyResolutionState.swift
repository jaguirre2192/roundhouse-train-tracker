import TrainTrackerCore

struct JourneyResolutionState {
    private(set) var plan: JourneyPlanResolution?
    private(set) var failures: [JourneyResolutionFailure] = []
    private(set) var availableSubsetConfirmed = false
    private(set) var trackingFailed = false

    var availableTripCount: Int {
        var identifiers: Set<RailIdentifier> = []
        for trip in plan?.directions.flatMap(\.segments).compactMap(\.trip) ?? [] {
            identifiers.insert(trip.id)
        }
        return identifiers.count
    }

    var canTrackAvailableTrips: Bool {
        guard plan != nil, availableTripCount > 0 else { return false }
        return failures.isEmpty || availableSubsetConfirmed
    }

    mutating func apply(
        _ resolution: JourneyPlanResolution,
        failures: [JourneyResolutionFailure]
    ) {
        plan = resolution
        self.failures = failures
        availableSubsetConfirmed = false
        trackingFailed = false
    }

    mutating func confirmAvailableSubset() {
        guard !failures.isEmpty, availableTripCount > 0 else { return }
        availableSubsetConfirmed = true
    }

    mutating func setAvailableSubsetConfirmed(_ confirmed: Bool) {
        guard !failures.isEmpty, availableTripCount > 0 else {
            availableSubsetConfirmed = false
            return
        }
        availableSubsetConfirmed = confirmed
    }

    mutating func recordTrackingFailure() {
        trackingFailed = true
    }

    mutating func clearTrackingFailure() {
        trackingFailed = false
    }

    mutating func reset() {
        self = JourneyResolutionState()
    }
}
