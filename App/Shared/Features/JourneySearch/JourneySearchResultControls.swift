import TrainTrackerCore

extension JourneySearchStore {
    var visibleOutboundOptions: [JourneyOption] {
        visibleOptions(in: outboundPage)
    }

    var visibleReturnOptions: [JourneyOption] {
        visibleOptions(in: returnPage)
    }

    func loadEarlierOutbound() {
        guard let cursor = outboundPage?.previousCursor else { return }
        searchOutbound(cursor: cursor)
    }

    func loadLaterOutbound() {
        guard let cursor = outboundPage?.nextCursor else { return }
        searchOutbound(cursor: cursor)
    }

    func loadEarlierReturn() {
        guard let cursor = returnPage?.previousCursor else { return }
        searchReturn(cursor: cursor)
    }

    func loadLaterReturn() {
        guard let cursor = returnPage?.nextCursor else { return }
        searchReturn(cursor: cursor)
    }

    func rerunWithMaximumTransfers(
        _ maximumTransfers: Int,
        direction: JourneySearchDirection
    ) {
        guard applyResultMaximumTransfers(maximumTransfers) else { return }
        switch direction {
        case .outbound:
            rerunOutboundForResultControls()
        case .return:
            rerunReturnForResultControls()
        }
    }

    private func visibleOptions(in page: JourneySearchPage?) -> [JourneyOption] {
        guard let options = page?.options else { return [] }
        let filtered = JourneyResultFiltering.options(in: options, directOnly: form.directOnly)
        return JourneyImportedTrainPreference.ranked(filtered, trainNumber: preferredTrainNumber)
    }
}
