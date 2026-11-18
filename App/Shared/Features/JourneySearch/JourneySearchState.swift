import Foundation
import TrainTrackerCore

enum JourneySearchFailureReason: Equatable {
    case offline
    case timedOut
    case serviceUnavailable
    case rateLimited
    case invalidRequest
    case invalidResponse

    init(error: Error) {
        if let error = error as? JourneySearchClient.ClientError {
            switch error {
            case .offline: self = .offline
            case .timedOut: self = .timedOut
            case .serviceUnavailable, .rejected: self = .serviceUnavailable
            case .rateLimited: self = .rateLimited
            case .invalidRequest, .notConfigured: self = .invalidRequest
            case .invalidResponse, .trackingTokenExpired: self = .invalidResponse
            }
            return
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                self = .offline
            case .timedOut:
                self = .timedOut
            default:
                self = .serviceUnavailable
            }
            return
        }
        self = .serviceUnavailable
    }
}

enum JourneySearchFailure: Equatable {
    case outboundSearchUnavailable
    case returnSearchUnavailable
    case resolutionUnavailable
    case trackingTokenExpired
}

enum JourneySearchPhase: Equatable {
    case editing
    case loadingOutbound
    case showingOutbound
    case loadingReturn
    case showingReturn
    case reviewing
    case resolving
    case completed(planID: UUID)
    case failed(JourneySearchFailure)
}

enum JourneySearchDirection: Equatable {
    case outbound
    case `return`
}

struct JourneyResolutionFailure: Equatable, Identifiable {
    let directionFingerprint: String
    let segmentID: String
    let code: JourneyPlanResolution.Failure.Code
    let message: String
    let occurrence: Int

    init(
        directionFingerprint: String,
        segmentID: String,
        code: JourneyPlanResolution.Failure.Code,
        message: String,
        occurrence: Int = 0
    ) {
        self.directionFingerprint = directionFingerprint
        self.segmentID = segmentID
        self.code = code
        self.message = message
        self.occurrence = occurrence
    }

    var id: String { "\(directionFingerprint):\(segmentID):\(occurrence)" }
}

@MainActor
protocol JourneyPlanTracking: AnyObject {
    func track(
        draft: JourneyPlanDraft,
        resolution: JourneyPlanResolution
    ) throws -> TrackedJourneyPlan
}

extension JourneyPlanLibrary: JourneyPlanTracking {}
