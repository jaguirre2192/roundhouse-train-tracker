import TrainTrackerCore

extension JourneySearchStore {
    var resolutionSummary: JourneyResolutionSummary? {
        guard let resolution = resolutionState.plan else { return nil }
        return JourneyResolutionSummary(
            resolution: resolution,
            selectedOptions: selectedJourneyOptions,
            isRoundTrip: selectedReturn != nil,
            availableSubsetConfirmed: resolutionState.availableSubsetConfirmed
        )
    }

    func setAvailableSubsetConfirmed(_ confirmed: Bool) {
        resolutionState.setAvailableSubsetConfirmed(confirmed)
    }

    func applyResolvedPlan(_ resolution: JourneyPlanResolution) {
        let summary = JourneyResolutionSummary(
            resolution: resolution,
            selectedOptions: selectedJourneyOptions,
            isRoundTrip: selectedReturn != nil,
            availableSubsetConfirmed: false
        )
        resolutionState.apply(resolution, failures: summary.failures)
    }

    @discardableResult
    func trackResolvedPlan() -> Bool {
        guard phase == .reviewing,
              canTrackAvailableTrips,
              let resolution = resolvedPlan,
              let draft = reviewDraftForTracking else { return false }
        beginTrackingPersistence()
        do {
            let plan = try persistJourneyPlan(draft: draft, resolution: resolution)
            finishTrackingPersistence(planID: plan.id)
            return true
        } catch {
            failTrackingPersistence()
            return false
        }
    }

    private var selectedJourneyOptions: [JourneyOption] {
        [selectedOutbound, selectedReturn].compactMap { $0 }
    }
}
