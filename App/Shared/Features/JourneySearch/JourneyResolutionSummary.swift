import TrainTrackerCore

struct JourneyResolutionSummary: Equatable {
    enum State: Equatable {
        case all
        case partial
        case none
    }

    static let pushWarningCopy = JourneySearchCopy.Resolution.pushWarning

    let state: State
    let availableTripCount: Int
    let failures: [JourneyResolutionFailure]
    let isRoundTrip: Bool
    let availableSubsetConfirmed: Bool
    let coverage: JourneyCoverageSummary

    init(
        resolution: JourneyPlanResolution,
        selectedOptions: [JourneyOption] = [],
        isRoundTrip: Bool,
        availableSubsetConfirmed: Bool
    ) {
        var tripIDs: Set<RailIdentifier> = []
        var failures: [JourneyResolutionFailure] = []
        var responseFailureCoverage: [FailureIdentity: Int] = [:]
        var nextOccurrence: [FailureIdentity: Int] = [:]

        for direction in resolution.directions {
            for segment in direction.segments {
                if let trip = segment.trip {
                    tripIDs.insert(trip.id)
                }
                if let failure = segment.failure {
                    let identity = FailureIdentity(
                        directionFingerprint: direction.fingerprint,
                        segmentID: segment.segmentID
                    )
                    let occurrence = nextOccurrence[identity, default: 0]
                    nextOccurrence[identity] = occurrence + 1
                    responseFailureCoverage[identity, default: 0] += 1
                    failures.append(JourneyResolutionFailure(
                        directionFingerprint: direction.fingerprint,
                        segmentID: segment.segmentID,
                        code: failure.code,
                        message: failure.message,
                        occurrence: occurrence
                    ))
                }
            }
        }

        for option in selectedOptions {
            for case let .rail(rail) in option.segments where !rail.isTrackable {
                let identity = FailureIdentity(
                    directionFingerprint: option.fingerprint,
                    segmentID: rail.id
                )
                if responseFailureCoverage[identity, default: 0] > 0 {
                    responseFailureCoverage[identity, default: 0] -= 1
                    continue
                }
                let occurrence = nextOccurrence[identity, default: 0]
                nextOccurrence[identity] = occurrence + 1
                failures.append(JourneyResolutionFailure(
                    directionFingerprint: option.fingerprint,
                    segmentID: rail.id,
                    code: .notFound,
                    message: rail.untrackableReason ?? JourneySearchCopy.Status.providerCannotTrack,
                    occurrence: occurrence
                ))
            }
        }

        availableTripCount = tripIDs.count
        coverage = JourneyCoverageSummary(resolution: resolution)
        self.failures = failures
        self.isRoundTrip = isRoundTrip
        self.availableSubsetConfirmed = availableSubsetConfirmed
        if tripIDs.isEmpty {
            state = .none
        } else if failures.isEmpty {
            state = .all
        } else {
            state = .partial
        }
    }

    var statusTitle: String {
        switch state {
        case .all: coverage.notice == nil && !coverage.isScheduleOnly
            ? JourneySearchCopy.Resolution.allReady
            : JourneySearchCopy.Coverage.readyToSave
        case .partial: JourneySearchCopy.Resolution.partial
        case .none: JourneySearchCopy.Resolution.none
        }
    }

    var primaryActionTitle: String {
        if state == .partial {
            return JourneySearchCopy.Resolution.trackAvailable(count: availableTripCount)
        }
        if coverage.isScheduleOnly {
            return isRoundTrip ? JourneySearchCopy.Coverage.saveRoundTrip : JourneySearchCopy.Coverage.saveJourney
        }
        return isRoundTrip
            ? JourneySearchCopy.Resolution.trackRoundTrip
            : JourneySearchCopy.Resolution.trackJourney
    }

    var subsetConsentLabel: String {
        JourneySearchCopy.Resolution.subsetConsent(count: availableTripCount)
    }

    var retryActionTitle: String { JourneySearchCopy.Resolution.retryUnavailable }

    var showsSubsetConsent: Bool { state == .partial }
    var showsRetryAction: Bool { state != .all }

    var canTrack: Bool {
        switch state {
        case .all: true
        case .partial: availableSubsetConfirmed
        case .none: false
        }
    }

    private struct FailureIdentity: Hashable {
        let directionFingerprint: String
        let segmentID: String
    }
}
