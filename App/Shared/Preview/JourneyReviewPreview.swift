#if DEBUG
import Foundation
import TrainTrackerCore

enum JourneyReviewPreviewMode: CaseIterable, Equatable, Sendable {
    case all
    case partial
    case none
    /// Coverage disclosure QA: every train resolves; what differs is what its sources provide.
    case coverageMixed
    case coverageScheduleOnly
    case coverageUnconfirmed
    case coverageRegional
    case coverageOutage

    static func resolve(arguments: [String]) -> Self? {
        if arguments.contains("-JourneyReviewPreviewCoverageMixed") { return .coverageMixed }
        if arguments.contains("-JourneyReviewPreviewCoverageScheduleOnly") { return .coverageScheduleOnly }
        if arguments.contains("-JourneyReviewPreviewCoverageUnconfirmed") { return .coverageUnconfirmed }
        if arguments.contains("-JourneyReviewPreviewCoverageRegional") { return .coverageRegional }
        if arguments.contains("-JourneyReviewPreviewCoverageOutage") { return .coverageOutage }
        if arguments.contains("-JourneyReviewPreviewAll") { return .all }
        if arguments.contains("-JourneyReviewPreviewPartial") { return .partial }
        if arguments.contains("-JourneyReviewPreviewNone") { return Self.none }
        return nil
    }

    @MainActor
    func bootstrap(_ store: JourneySearchStore) async {
        guard store.phase == .editing else { return }
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        guard let outbound = store.visibleOutboundOptions.first(where: { $0.id == "preview-direct" })
        else { return }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        guard let returnOption = store.visibleReturnOptions.first else { return }
        store.selectReturn(returnOption)
    }

    func resolution(fixture: JourneyResultsPreviewFixture) -> JourneyPlanResolution {
        guard let outbound = fixture.outboundPage.options.first(where: { $0.id == "preview-direct" }),
              let returnOption = fixture.returnPage.options.first else {
            return JourneyPlanResolution(directions: [])
        }
        let trips = PreviewTrips.make(referenceDate: outbound.startTime)

        typealias State = JourneyCoverage.FeatureState
        let everyFeature = JourneyCoverage.Feature.allCases
        let connected = JourneyCoverage(features: Dictionary(uniqueKeysWithValues: everyFeature.map {
            ($0, State(support: .connected, availability: $0 == .cancellations ? .notObserved : .observed))
        }))
        let scheduleOnly = JourneyCoverage(features: Dictionary(uniqueKeysWithValues: everyFeature.map {
            ($0, State(support: .notProvided))
        }))
        let regional = JourneyCoverage(
            features: [.position: State(support: .connected, availability: .observed, observedAt: .now)],
            scopeName: "PID regional rail",
            limitationCodes: ["regionalScope"]
        )
        let noLocation = JourneyCoverage(features: [
            .delays: State(support: .connected), .cancellations: State(support: .connected),
            .platforms: State(support: .connected), .position: State(support: .notProvided),
        ])

        func both(_ outboundCoverage: JourneyCoverage, _ returnCoverage: JourneyCoverage) -> JourneyPlanResolution {
            JourneyPlanResolution(directions: [
                direction(option: outbound, trips: [trips[0]], failure: nil, coverage: outboundCoverage),
                direction(option: returnOption, trips: [trips[1]], failure: nil, coverage: returnCoverage),
            ])
        }

        switch self {
        case .all:
            return both(connected, connected)
        case .coverageMixed:
            return both(connected, scheduleOnly)
        case .coverageScheduleOnly:
            return both(scheduleOnly, scheduleOnly)
        case .coverageUnconfirmed:
            return both(.unconfirmed, .unconfirmed)
        case .coverageRegional:
            return both(regional, noLocation)
        case .coverageOutage:
            return both(.unavailable, .unavailable)
        case .partial:
            return JourneyPlanResolution(directions: [
                direction(option: outbound, trips: [trips[0]], failure: nil, coverage: connected),
                direction(
                    option: returnOption,
                    trips: [],
                    failure: .init(
                        code: .providerUnavailable,
                        message: "Return train is temporarily unavailable"
                    )
                ),
            ])
        case .none:
            return JourneyPlanResolution(directions: [
                direction(
                    option: outbound,
                    trips: [],
                    failure: .init(code: .notFound, message: "Outbound train could not be matched")
                ),
                direction(
                    option: returnOption,
                    trips: [],
                    failure: .init(
                        code: .providerUnavailable,
                        message: "Return train is temporarily unavailable"
                    )
                ),
            ])
        }
    }

    private func direction(
        option: JourneyOption,
        trips: [TrainTrip],
        failure: JourneyPlanResolution.Failure?,
        coverage: JourneyCoverage = .unconfirmed
    ) -> JourneyPlanResolution.Direction {
        let railSegments = option.segments.compactMap { segment -> RailJourneySegment? in
            guard case let .rail(rail) = segment else { return nil }
            return rail
        }
        let tripSegments = trips.enumerated().map { index, trip in
            JourneyPlanResolution.Segment(
                segmentID: railSegments.indices.contains(index)
                    ? railSegments[index].id : "\(option.id)-resolved-\(index)",
                trip: trip,
                failure: nil,
                coverage: coverage
            )
        }
        let failedSegments = failure.map {
            [JourneyPlanResolution.Segment(
                segmentID: railSegments.first?.id ?? "\(option.id)-unavailable",
                trip: nil,
                failure: $0
            )]
        } ?? []
        return JourneyPlanResolution.Direction(
            fingerprint: option.fingerprint,
            originStationID: railSegments.first?.from.place.id
                ?? RailIdentifier(rawValue: "preview:origin"),
            destinationStationID: railSegments.last?.to.place.id
                ?? RailIdentifier(rawValue: "preview:destination"),
            departure: option.startTime,
            arrival: option.endTime,
            segments: tripSegments + failedSegments
        )
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
#endif
