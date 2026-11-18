import Foundation
import Observation
import TrainTrackerCore

@MainActor
@Observable
final class JourneyRecoveryStore {
    enum Result: Equatable {
        case loading, empty, unavailable, candidate(JourneyRecoveryOption)
    }

    private(set) var result: Result = .loading
    private(set) var isSaving = false
    private(set) var saveMessage: String?
    private let client: any JourneySearching
    private var loadVersion = UUID()
    private var nextCheck = Date.distantPast

    init(client: any JourneySearching = JourneySearchClient()) { self.client = client }

    func load(_ request: JourneyRecoveryRequest, at date: Date, force: Bool = false) async {
        guard force || date >= nextCheck else { return }
        let version = UUID()
        loadVersion = version
        nextCheck = .distantFuture
        result = .loading
        var criteria = request.criteria(at: date)
        var cursors = Set<String>()
        do {
            // An earlier page can contain only the booked train or trains that have already gone.
            for _ in 0..<3 {
                let page = try await client.searchJourneys(criteria: criteria)
                try Task.checkCancellation()
                guard version == loadVersion else { return }
                if let candidate = JourneyRecoveryOption.next(in: page, request: request, at: date) {
                    result = .candidate(candidate)
                    nextCheck = min(candidate.departure, candidate.expiresAt)
                    return
                }
                guard page.expiresAt > date, let cursor = page.nextCursor,
                      cursors.insert(cursor).inserted else { break }
                criteria = JourneySearchCriteria(originID: criteria.originID, destinationID: criteria.destinationID,
                    requestedTime: criteria.requestedTime, timeZoneIdentifier: criteria.timeZoneIdentifier,
                    arriveBy: false, maximumTransfers: criteria.maximumTransfers, cursor: cursor)
            }
            result = .empty
            nextCheck = date.addingTimeInterval(5 * 60)
        } catch {
            guard version == loadVersion else { return }
            if Task.isCancelled {
                nextCheck = .distantPast
                return
            }
            result = .unavailable
            nextCheck = date.addingTimeInterval(5 * 60)
        }
    }

    func follow(_ candidate: JourneyRecoveryOption, request: JourneyRecoveryRequest,
                planID: UUID, in plans: JourneyPlanLibrary, now: () -> Date) async {
        guard !isSaving else { return }
        isSaving = true
        saveMessage = nil
        defer { isSaving = false }
        do {
            let resolved = try await client.resolvePlan(trackingTokens: [candidate.option.trackingToken])
            let date = now()
            try Task.checkCancellation()
            guard candidate.stillUsable(resolved, request: request, at: date) else {
                saveMessage = "This option changed. Check the latest departure before following it."
                await load(request, at: date, force: true)
                return
            }
            let draft = JourneyPlanDraft(id: Self.planID(for: candidate, basedOn: planID),
                origin: request.origin, destination: request.destination, outbound: candidate.option, returnOption: nil)
            try plans.followAlternative(draft: draft, resolution: resolved)
        } catch {
            guard !Task.isCancelled else { return }
            if JourneySelectionRecovery.isTrackingTokenExpired(error) {
                saveMessage = "These times expired. Review the updated option."
                await load(request, at: now(), force: true)
            } else {
                saveMessage = "Couldn’t follow this option. Try again or search other trains."
            }
        }
    }

    static func planID(for candidate: JourneyRecoveryOption, basedOn original: UUID) -> UUID {
        JourneyDraftIdentity.stableID(seed: original, fingerprint: "alternative-" + candidate.option.fingerprint)
    }
}
