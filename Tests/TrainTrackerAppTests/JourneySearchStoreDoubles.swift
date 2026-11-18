import Foundation
import TrainTrackerCore
@testable import TrainTracker

actor ScriptedJourneySearchClient: JourneySearching {
    enum StubFailure: Error, Sendable {
        case unavailable
        case cancelled
        case trackingTokenExpired
    }

    enum PlaceResponse: Sendable {
        case success([RailPlace])
        case failure(StubFailure)
    }

    enum PageResponse: Sendable {
        case success(JourneySearchPage)
        case failure(StubFailure)
    }

    enum ResolutionResponse: Sendable {
        case success(JourneyPlanResolution)
        case failure(StubFailure)
    }

    private var placeResponses: [PlaceResponse]
    private var pageResponses: [PageResponse]
    private var resolutionResponses: [ResolutionResponse]
    private(set) var placeRequests: [(query: String, limit: Int)] = []
    private(set) var journeyRequests: [JourneySearchCriteria] = []
    private(set) var resolutionRequests: [[String]] = []

    var resolutionRequestCount: Int { resolutionRequests.count }

    init(
        places: [PlaceResponse] = [],
        pages: [PageResponse] = [],
        resolutions: [ResolutionResponse] = []
    ) {
        placeResponses = places
        pageResponses = pages
        resolutionResponses = resolutions
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] {
        placeRequests.append((query, limit))
        guard !placeResponses.isEmpty else { throw StubFailure.unavailable }
        switch placeResponses.removeFirst() {
        case let .success(places): return places
        case .failure(.cancelled): throw CancellationError()
        case .failure(.trackingTokenExpired):
            throw JourneySearchClient.ClientError.trackingTokenExpired
        case .failure(.unavailable): throw StubFailure.unavailable
        }
    }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        journeyRequests.append(criteria)
        guard !pageResponses.isEmpty else { throw StubFailure.unavailable }
        switch pageResponses.removeFirst() {
        case let .success(page): return page
        case .failure(.cancelled): throw CancellationError()
        case .failure(.trackingTokenExpired):
            throw JourneySearchClient.ClientError.trackingTokenExpired
        case .failure(.unavailable): throw StubFailure.unavailable
        }
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        resolutionRequests.append(trackingTokens)
        guard !resolutionResponses.isEmpty else { throw StubFailure.unavailable }
        switch resolutionResponses.removeFirst() {
        case let .success(resolution): return resolution
        case .failure(.cancelled): throw CancellationError()
        case .failure(.trackingTokenExpired):
            throw JourneySearchClient.ClientError.trackingTokenExpired
        case .failure(.unavailable): throw StubFailure.unavailable
        }
    }
}

actor StaleJourneySearchClient: JourneySearching {
    private let replacementPage: JourneySearchPage
    private var firstContinuation: CheckedContinuation<JourneySearchPage, Never>?
    private(set) var journeyRequests: [JourneySearchCriteria] = []

    init(replacementPage: JourneySearchPage) {
        self.replacementPage = replacementPage
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] { [] }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        journeyRequests.append(criteria)
        if journeyRequests.count == 1 {
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return replacementPage
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        JourneyPlanResolution(directions: [])
    }

    func waitForFirstRequest() async {
        while firstContinuation == nil { await Task.yield() }
    }

    func resumeFirst(with page: JourneySearchPage) {
        firstContinuation?.resume(returning: page)
        firstContinuation = nil
    }
}

actor StalePlaceJourneySearchClient: JourneySearching {
    private let replacementPlaces: [RailPlace]
    private var firstContinuation: CheckedContinuation<[RailPlace], Never>?
    private(set) var placeQueries: [String] = []

    init(replacementPlaces: [RailPlace]) {
        self.replacementPlaces = replacementPlaces
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] {
        placeQueries.append(query)
        if placeQueries.count == 1 {
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return replacementPlaces
    }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        JourneySearchStoreFixtures.page(options: [])
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        JourneyPlanResolution(directions: [])
    }

    func waitForFirstRequest() async {
        while firstContinuation == nil { await Task.yield() }
    }

    func resumeFirst(with places: [RailPlace]) {
        firstContinuation?.resume(returning: places)
        firstContinuation = nil
    }
}

actor StaleReturnJourneySearchClient: JourneySearching {
    private let outboundPage: JourneySearchPage
    private var returnContinuation: CheckedContinuation<JourneySearchPage, Never>?
    private(set) var journeyRequests: [JourneySearchCriteria] = []

    init(outboundPage: JourneySearchPage) {
        self.outboundPage = outboundPage
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] { [] }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        journeyRequests.append(criteria)
        if journeyRequests.count == 1 { return outboundPage }
        return await withCheckedContinuation { returnContinuation = $0 }
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        JourneyPlanResolution(directions: [])
    }

    func waitForReturnRequest() async {
        while returnContinuation == nil { await Task.yield() }
    }

    func resumeReturn(with page: JourneySearchPage) {
        returnContinuation?.resume(returning: page)
        returnContinuation = nil
    }
}

actor StaleResolutionJourneySearchClient: JourneySearching {
    private let outboundPage: JourneySearchPage
    private var resolutionContinuation: CheckedContinuation<JourneyPlanResolution, Never>?

    init(outboundPage: JourneySearchPage) {
        self.outboundPage = outboundPage
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] { [] }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        outboundPage
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        await withCheckedContinuation { resolutionContinuation = $0 }
    }

    func waitForResolutionRequest() async {
        while resolutionContinuation == nil { await Task.yield() }
    }

    func resumeResolution(with resolution: JourneyPlanResolution) {
        resolutionContinuation?.resume(returning: resolution)
        resolutionContinuation = nil
    }
}

actor RetryingResolutionJourneySearchClient: JourneySearching {
    private let outboundPage: JourneySearchPage
    private var resolutionContinuations: [CheckedContinuation<JourneyPlanResolution, Never>?] = []

    init(outboundPage: JourneySearchPage) {
        self.outboundPage = outboundPage
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] { [] }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        outboundPage
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        let index = resolutionContinuations.count
        resolutionContinuations.append(nil)
        return await withCheckedContinuation { resolutionContinuations[index] = $0 }
    }

    func waitForRequest(count: Int) async {
        while resolutionContinuations.count < count
            || resolutionContinuations.prefix(count).contains(where: { $0 == nil }) {
            await Task.yield()
        }
    }

    func resumeRequest(at index: Int, with resolution: JourneyPlanResolution) {
        resolutionContinuations[index]?.resume(returning: resolution)
        resolutionContinuations[index] = nil
    }
}

@MainActor
final class RecordingJourneyPlanTracker: JourneyPlanTracking {
    enum StubError: Error { case save }

    var shouldFail = false
    private(set) var calls: [(draft: JourneyPlanDraft, resolution: JourneyPlanResolution)] = []

    func track(
        draft: JourneyPlanDraft,
        resolution: JourneyPlanResolution
    ) throws -> TrackedJourneyPlan {
        calls.append((draft, resolution))
        if shouldFail { throw StubError.save }
        let outbound = resolution.directions[0]
        let returnDirection = resolution.directions.count > 1 ? resolution.directions[1] : nil
        return TrackedJourneyPlan(
            id: draft.id,
            createdAt: JourneySearchStoreFixtures.date("2026-07-21T12:00:00Z"),
            origin: draft.origin,
            destination: draft.destination,
            outbound: JourneyPlanDirection(
                fingerprint: outbound.fingerprint,
                departure: outbound.departure,
                arrival: outbound.arrival,
                childTripIDs: outbound.segments.compactMap { $0.trip?.id }
            ),
            returnDirection: returnDirection.map {
                JourneyPlanDirection(
                    fingerprint: $0.fingerprint,
                    departure: $0.departure,
                    arrival: $0.arrival,
                    childTripIDs: $0.segments.compactMap { $0.trip?.id }
                )
            },
            preExistingChildTripIDs: []
        )
    }
}
