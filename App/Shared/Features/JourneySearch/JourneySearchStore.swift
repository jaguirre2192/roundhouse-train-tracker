import CryptoKit
import Foundation
import Observation
import TrainTrackerCore

@MainActor
@Observable
final class JourneySearchStore {
    private(set) var phase: JourneySearchPhase = .editing
    private(set) var form: JourneySearchFormState
    private(set) var outboundPage: JourneySearchPage?
    private(set) var returnPage: JourneySearchPage?
    private(set) var selectedOutbound: JourneyOption?
    private(set) var selectedReturn: JourneyOption?
    private(set) var earliestValidReturnTime: Date?
    private(set) var selectionNeedsReview = false
    private(set) var placeResults: [RailPlace] = []
    private(set) var placeLookupFailed = false
    private(set) var journeyFailureReason: JourneySearchFailureReason?
    private(set) var preferredTrainNumber: String?
    private(set) var importedReviewMessage: String?

    private let client: any JourneySearching
    private let planTracker: any JourneyPlanTracking
    private var placeLookupTask: Task<Void, Never>?
    private var journeyTask: Task<Void, Never>?
    private var placeRequestID = 0
    private var journeyRequestID = 0
    private var ticketPrefillRequestID = 0
    private var outboundCriteria: JourneySearchCriteria?
    private var returnCriteria: JourneySearchCriteria?
    private var continuingAsOneWay = false
    private var draftID = UUID()
    private var calendarSource: CalendarJourneySource?
    private var isReviewingImportedMatch = false
    var resolutionState = JourneyResolutionState()
    /// An import's durable identity. Tracking the same selected journey from the same import
    /// reuses one plan ID, so retries and relaunches update rather than duplicate it.
    var importDraftSeed: UUID?

    init(
        client: any JourneySearching,
        planTracker: any JourneyPlanTracking,
        form: JourneySearchFormState = JourneySearchFormState()
    ) {
        self.client = client
        self.planTracker = planTracker
        self.form = form
    }

    var isJourneyTaskActive: Bool {
        journeyTask != nil
    }

    var isPlaceLookupTaskActive: Bool {
        placeLookupTask != nil
    }

    var canEditSearch: Bool {
        switch phase {
        case .editing, .completed, .failed(.outboundSearchUnavailable): false
        default: true
        }
    }

    var availableTripCount: Int {
        resolutionState.availableTripCount
    }

    var canTrackAvailableTrips: Bool {
        resolutionState.canTrackAvailableTrips
    }

    var resolvedPlan: JourneyPlanResolution? { resolutionState.plan }
    var resolutionFailures: [JourneyResolutionFailure] { resolutionState.failures }
    var availableSubsetConfirmed: Bool { resolutionState.availableSubsetConfirmed }
    var trackingFailed: Bool { resolutionState.trackingFailed }

    func prefillTicketJourney(_ request: TicketJourneySearchRequest) async {
        cancelPlaceLookup()
        resetAllSearchState()
        let requestID = ticketPrefillRequestID
        calendarSource = request.calendarSource
        placeLookupFailed = false
        preferredTrainNumber = request.trainNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        form = JourneySearchFormState(outboundTime: .now, returnEnabled: false)

        do {
            let prefill = try await ImportedJourneyPrefill.resolve(request, using: client)
            guard ticketPrefillRequestID == requestID else { return }
            calendarSource = prefill.calendarSource
            form.origin = prefill.origin
            form.destination = prefill.destination
            if let requestedTime = prefill.departureTime {
                form.outboundTime = requestedTime
                form.returnTime = requestedTime
            }
            // A ticket without a departure date should prefill a correctable
            // form, not silently search for unrelated trains leaving today.
            guard form.canSearch, prefill.departureTime != nil else { return }
            searchOutbound(cursor: nil, importedSelection: prefill.directReview)
        } catch is CancellationError {
            return
        } catch {
            guard ticketPrefillRequestID == requestID else { return }
            placeLookupFailed = true
        }
    }

    func lookupPlaces(query: String, limit: Int = 20) {
        cancelPlaceLookup()
        placeLookupFailed = false
        let requestID = placeRequestID
        placeLookupTask = Task { [weak self, client] in
            do {
                let places = try await client.searchPlaces(query: query, limit: limit)
                guard let self, self.placeRequestID == requestID else { return }
                self.placeResults = places
                self.finishPlaceLookup(requestID: requestID)
            } catch is CancellationError {
                self?.finishPlaceLookup(requestID: requestID)
            } catch {
                guard let self, self.placeRequestID == requestID else { return }
                self.placeLookupFailed = true
                self.finishPlaceLookup(requestID: requestID)
            }
        }
    }

    func searchOutbound(cursor: String? = nil) {
        ticketPrefillRequestID += 1
        searchOutbound(cursor: cursor, importedSelection: nil)
    }

    private func searchOutbound(cursor: String?, importedSelection: ImportedJourneyAutoSelection?) {
        guard let criteria = form.outboundCriteria(cursor: cursor) else { return }
        cancelJourneyTask()
        resetResolutionState()
        importedReviewMessage = nil
        isReviewingImportedMatch = false
        journeyFailureReason = nil
        outboundCriteria = criteria
        phase = .loadingOutbound
        let requestID = journeyRequestID
        journeyTask = Task { [weak self, client] in
            do {
                let page = try await client.searchJourneys(criteria: criteria)
                guard let self, self.journeyRequestID == requestID else { return }
                self.outboundPage = page
                self.selectedOutbound = nil
                self.returnPage = nil
                self.selectedReturn = nil
                self.phase = .showingOutbound
                self.finishJourneyTask(requestID: requestID)
                if let importedSelection {
                    switch importedSelection.decision(in: page.options) {
                    case let .review(option):
                        self.selectOutbound(option)
                        self.isReviewingImportedMatch = self.phase == .reviewing
                    case let .choose(reason):
                        self.importedReviewMessage = reason.message
                    }
                }
            } catch is CancellationError {
                self?.finishJourneyTask(requestID: requestID)
            } catch {
                guard let self, self.journeyRequestID == requestID else { return }
                self.journeyFailureReason = JourneySearchFailureReason(error: error)
                self.phase = .failed(.outboundSearchUnavailable)
                self.finishJourneyTask(requestID: requestID)
            }
        }
    }

    func selectOutbound(_ option: JourneyOption) {
        guard visibleOutboundOptions.contains(option) else { return }
        isReviewingImportedMatch = false
        importedReviewMessage = nil
        cancelJourneyTask()
        resetResolutionState()
        draftID = importDraftSeed.map { JourneyDraftIdentity.stableID(seed: $0, fingerprint: option.fingerprint) } ?? UUID()
        selectedOutbound = option
        selectedReturn = nil
        returnPage = nil
        continuingAsOneWay = false
        selectionNeedsReview = false
        earliestValidReturnTime = nil
        guard form.returnEnabled else {
            phase = .reviewing
            return
        }
        searchReturn()
    }

    var canChooseAnotherImportedTrain: Bool {
        guard isReviewingImportedMatch, selectedOutbound != nil, outboundPage != nil else { return false }
        switch phase {
        case .reviewing, .resolving, .failed(.resolutionUnavailable), .failed(.trackingTokenExpired): return true
        default: return false
        }
    }

    func chooseAnotherImportedTrain() {
        guard canChooseAnotherImportedTrain else { return }
        cancelJourneyTask()
        resetResolutionState()
        isReviewingImportedMatch = false
        selectedOutbound = nil
        selectedReturn = nil
        selectionNeedsReview = false
        phase = .showingOutbound
    }

    /// Returns from a one-way review to the already fetched departures without a new search.
    var canReturnToOutboundResults: Bool {
        guard !form.returnEnabled, selectedOutbound != nil, outboundPage != nil else { return false }
        switch phase {
        case .reviewing, .resolving, .failed(.resolutionUnavailable), .failed(.trackingTokenExpired): return true
        default: return false
        }
    }

    func returnToOutboundResults() {
        guard canReturnToOutboundResults else { return }
        cancelJourneyTask()
        resetResolutionState()
        isReviewingImportedMatch = false
        selectedOutbound = nil
        selectedReturn = nil
        selectionNeedsReview = false
        phase = .showingOutbound
    }

    func selectReturn(_ option: JourneyOption) {
        guard visibleReturnOptions.contains(option) else { return }
        resetResolutionState()
        selectedReturn = option
        continuingAsOneWay = false
        selectionNeedsReview = false
        phase = .reviewing
    }

    func acceptAdjustedReturnSearch() {
        guard let earliestValidReturnTime else { return }
        form.returnTime = earliestValidReturnTime
        self.earliestValidReturnTime = nil
        searchReturn()
    }

    func editReturn() {
        guard selectedOutbound != nil, form.returnEnabled else { return }
        cancelJourneyTask()
        resetResolutionState()
        selectedReturn = nil
        earliestValidReturnTime = nil
        continuingAsOneWay = false
        phase = .showingReturn
    }

    func continueAsOneWay() {
        guard selectedOutbound != nil else { return }
        cancelJourneyTask()
        resetResolutionState()
        selectedReturn = nil
        earliestValidReturnTime = nil
        continuingAsOneWay = true
        phase = .reviewing
    }

    func resolveSelection() {
        guard let snapshot = currentSelectionSnapshot else { return }
        cancelJourneyTask()
        resetResolutionState()
        phase = .resolving
        let requestID = journeyRequestID
        journeyTask = Task { [weak self, client] in
            do {
                let outcome = try await JourneySelectionRecovery.resolve(
                    client: client,
                    snapshot: snapshot
                )
                guard let self, self.journeyRequestID == requestID else { return }
                self.apply(outcome)
                self.finishJourneyTask(requestID: requestID)
            } catch is CancellationError {
                self?.finishJourneyTask(requestID: requestID)
            } catch {
                guard let self, self.journeyRequestID == requestID else { return }
                self.phase = JourneySelectionRecovery.isTrackingTokenExpired(error)
                    ? .failed(.trackingTokenExpired)
                    : .failed(.resolutionUnavailable)
                self.finishJourneyTask(requestID: requestID)
            }
        }
    }

    func confirmAvailableSubset() {
        resolutionState.confirmAvailableSubset()
    }

    var reviewDraftForTracking: JourneyPlanDraft? {
        guard let draft = currentSelectionSnapshot?.draft else { return nil }
        return JourneyPlanDraft(
            id: draft.id, origin: draft.origin, destination: draft.destination,
            outbound: draft.outbound, returnOption: draft.returnOption,
            calendarSource: calendarSource
        )
    }

    func beginTrackingPersistence() {
        phase = .resolving
        resolutionState.clearTrackingFailure()
    }

    func persistJourneyPlan(
        draft: JourneyPlanDraft,
        resolution: JourneyPlanResolution
    ) throws -> TrackedJourneyPlan {
        try planTracker.track(draft: draft, resolution: resolution)
    }

    func finishTrackingPersistence(planID: UUID) {
        calendarSource = nil
        preferredTrainNumber = nil
        isReviewingImportedMatch = false
        importedReviewMessage = nil
        phase = .completed(planID: planID)
    }

    func failTrackingPersistence() {
        resolutionState.recordTrackingFailure()
        phase = .reviewing
    }

    func setOrigin(_ place: RailPlace?) {
        setPlaces(origin: place, destination: form.destination)
    }

    func setDestination(_ place: RailPlace?) {
        setPlaces(origin: form.origin, destination: place)
    }

    func setPlaces(origin: RailPlace?, destination: RailPlace?) {
        let originChanged = form.origin != origin
        let destinationChanged = form.destination != destination
        guard originChanged || destinationChanged else { return }
        if (originChanged && form.origin != nil) || (destinationChanged && form.destination != nil) {
            calendarSource = nil
        }
        cancelPlaceLookup()
        preferredTrainNumber = nil
        form.origin = origin
        form.destination = destination
        resetAllSearchState()
    }

    func swapPlaces() {
        calendarSource = nil
        preferredTrainNumber = nil
        form.swapPlaces()
        resetAllSearchState()
    }

    func setOutboundTime(_ time: Date) {
        guard form.outboundTime != time else { return }
        form.outboundTime = time
        if form.returnEnabled, form.returnTime < time {
            form.returnTime = time
        }
        resetAllSearchState()
    }

    func setOutboundArriveBy(_ arriveBy: Bool) {
        guard form.outboundArriveBy != arriveBy else { return }
        form.outboundArriveBy = arriveBy
        resetAllSearchState()
    }

    func setReturnEnabled(_ enabled: Bool) {
        guard form.returnEnabled != enabled else { return }
        form.returnEnabled = enabled
        if enabled, form.returnTime < form.outboundTime {
            form.returnTime = form.outboundTime
        }
        cancelJourneyTask()
        selectedReturn = nil
        returnPage = nil
        earliestValidReturnTime = nil
        continuingAsOneWay = false
        selectionNeedsReview = false
        resetResolutionState()
        if let selectedOutbound {
            phase = enabled ? .showingReturn : .reviewing
            self.selectedOutbound = selectedOutbound
        } else if outboundPage != nil {
            phase = .showingOutbound
        } else {
            phase = .editing
        }
    }

    func setReturnTime(_ time: Date) {
        let clamped = max(time, form.outboundTime)
        guard form.returnTime != clamped else { return }
        form.returnTime = clamped
        resetReturnSearchState()
    }

    func setReturnArriveBy(_ arriveBy: Bool) {
        guard form.returnArriveBy != arriveBy else { return }
        form.returnArriveBy = arriveBy
        resetReturnSearchState()
    }

    func setDirectOnly(_ directOnly: Bool) {
        guard form.directOnly != directOnly else { return }
        form.directOnly = directOnly
        let outboundStillVisible = selectedOutbound.map(visibleOutboundOptions.contains) ?? true
        let returnStillVisible = selectedReturn.map(visibleReturnOptions.contains) ?? true
        if !outboundStillVisible || !returnStillVisible {
            cancelJourneyTask()
            resetResolutionState()
        }
        if !outboundStillVisible {
            selectedOutbound = nil
        }
        if !returnStillVisible {
            selectedReturn = nil
        }
        if selectedOutbound == nil, outboundPage != nil {
            selectedReturn = nil
            phase = .showingOutbound
        } else if form.returnEnabled, !returnStillVisible, selectedOutbound != nil {
            // Only a return the filter just hid sends the person back to return results. A
            // one-way continuation or a failed return search keeps its state: switching to
            // return results with no page and no search would spin forever.
            if returnPage != nil {
                phase = .showingReturn
            } else {
                searchReturn()
            }
        }
    }

    func setMaximumTransfers(_ maximumTransfers: Int) {
        let bounded = min(max(maximumTransfers, 0), 4)
        guard form.maximumTransfers != bounded else { return }
        form.maximumTransfers = bounded
        resetAllSearchState()
    }

    func applyResultMaximumTransfers(_ maximumTransfers: Int) -> Bool {
        let bounded = min(max(maximumTransfers, 0), 4)
        guard form.maximumTransfers != bounded else { return false }
        form.maximumTransfers = bounded
        return true
    }

    func rerunOutboundForResultControls() {
        resetAllSearchState()
        searchOutbound()
    }

    func rerunReturnForResultControls() {
        guard selectedOutbound != nil, form.returnEnabled else {
            rerunOutboundForResultControls()
            return
        }
        resetReturnSearchState()
        searchReturn()
    }

    func cancelPlaceLookup() {
        placeRequestID += 1
        placeLookupTask?.cancel()
        placeLookupTask = nil
    }

    func cancelJourneyWork() {
        ticketPrefillRequestID += 1
        cancelJourneyTask()
    }

    func editSearch() {
        resetAllSearchState()
    }

    func searchReturn(cursor: String? = nil) {
        guard let outbound = selectedOutbound else { return }
        if proposeReturnAdjustmentIfNeeded(for: outbound, cursor: cursor) { return }
        guard let criteria = form.returnCriteria(cursor: cursor) else { return }
        cancelJourneyTask()
        returnCriteria = criteria
        journeyFailureReason = nil
        phase = .loadingReturn
        let requestID = journeyRequestID
        journeyTask = Task { [weak self, client] in
            do {
                let page = try await client.searchJourneys(criteria: criteria)
                guard let self, self.journeyRequestID == requestID else { return }
                self.returnPage = JourneySearchPolicy.filterReturnPage(page, after: outbound)
                self.selectedReturn = nil
                self.phase = .showingReturn
                self.finishJourneyTask(requestID: requestID)
            } catch is CancellationError {
                self?.finishJourneyTask(requestID: requestID)
            } catch {
                guard let self, self.journeyRequestID == requestID else { return }
                self.journeyFailureReason = JourneySearchFailureReason(error: error)
                self.phase = .failed(.returnSearchUnavailable)
                self.finishJourneyTask(requestID: requestID)
            }
        }
    }

    private func resetAllSearchState() {
        ticketPrefillRequestID += 1
        isReviewingImportedMatch = false
        importedReviewMessage = nil
        cancelJourneyTask()
        outboundPage = nil
        returnPage = nil
        selectedOutbound = nil
        selectedReturn = nil
        outboundCriteria = nil
        returnCriteria = nil
        earliestValidReturnTime = nil
        continuingAsOneWay = false
        selectionNeedsReview = false
        journeyFailureReason = nil
        resetResolutionState()
        phase = .editing
    }

    private func resetReturnSearchState() {
        cancelJourneyTask()
        returnPage = nil
        selectedReturn = nil
        returnCriteria = nil
        earliestValidReturnTime = nil
        continuingAsOneWay = false
        selectionNeedsReview = false
        journeyFailureReason = nil
        resetResolutionState()
        phase = selectedOutbound == nil ? (outboundPage == nil ? .editing : .showingOutbound) : .showingReturn
    }

    private func proposeReturnAdjustmentIfNeeded(
        for outbound: JourneyOption,
        cursor: String?
    ) -> Bool {
        let outboundArrival = outbound.effectiveEndpointDates.arrival
        guard cursor == nil, form.returnTime < outboundArrival else { return false }
        cancelJourneyTask()
        returnPage = nil
        selectedReturn = nil
        returnCriteria = nil
        earliestValidReturnTime = JourneySearchPolicy.ceilToFiveMinutes(
            outboundArrival,
            timeZoneIdentifier: form.returnTimeZoneIdentifier
        )
        continuingAsOneWay = false
        selectionNeedsReview = false
        resetResolutionState()
        phase = .showingReturn
        return true
    }

    private func cancelJourneyTask() {
        journeyRequestID += 1
        journeyTask?.cancel()
        journeyTask = nil
    }

    private func finishJourneyTask(requestID: Int) {
        guard journeyRequestID == requestID else { return }
        journeyTask = nil
    }

    private func finishPlaceLookup(requestID: Int) {
        guard placeRequestID == requestID else { return }
        placeLookupTask = nil
    }

    private var currentSelectionSnapshot: JourneySelectionSnapshot? {
        JourneySelectionSnapshot(
            draftID: draftID,
            form: form,
            outbound: selectedOutbound,
            returnOption: selectedReturn,
            continuingAsOneWay: continuingAsOneWay,
            outboundCriteria: outboundCriteria,
            returnCriteria: returnCriteria
        )
    }

    private func apply(_ outcome: JourneySelectionRecoveryOutcome) {
        switch outcome {
        case let .resolvedWithoutRefresh(resolution):
            applyResolvedPlan(resolution)
            phase = .reviewing
        case let .resolved(outboundPage, returnPage, outbound, returnOption, resolution):
            self.outboundPage = outboundPage
            self.returnPage = returnPage
            selectedOutbound = outbound
            selectedReturn = returnOption
            applyResolvedPlan(resolution)
            phase = .reviewing
        case let .outboundNeedsReview(page):
            outboundPage = page
            returnPage = nil
            selectedOutbound = nil
            selectedReturn = nil
            selectionNeedsReview = true
            phase = .showingOutbound
        case let .returnNeedsReview(outboundPage, outbound, returnPage):
            self.outboundPage = outboundPage
            self.returnPage = returnPage
            selectedOutbound = outbound
            selectedReturn = nil
            selectionNeedsReview = true
            phase = .showingReturn
        }
    }

    private func resetResolutionState() {
        resolutionState.reset()
    }

}

enum JourneyDraftIdentity {
    /// A deterministic UUID (version 5 layout) derived from an import and a journey fingerprint.
    static func stableID(seed: UUID, fingerprint: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((seed.uuidString + "|" + fingerprint).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
