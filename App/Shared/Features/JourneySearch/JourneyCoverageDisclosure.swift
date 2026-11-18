import Foundation
import TrainTrackerCore

/// One train's coverage, classified and worded for the review before saving.
struct JourneyCoverageDisclosure: Equatable {
    enum Kind: Equatable {
        /// Delays and train location are both established for this service.
        case connected
        /// Something live is established, but delays or location is not.
        case limited
        case scheduleOnly
        case unconfirmed
        /// A diagnosed failure of this check. Says nothing durable about the source.
        case unavailableNow
    }

    let kind: Kind
    let title: String
    let detail: String?

    init(coverage: JourneyCoverage) {
        typealias Copy = JourneySearchCopy.Coverage
        let established = coverage.established

        if coverage.isUnavailableNow {
            kind = .unavailableNow
            title = Copy.unavailableNow
            detail = Copy.unavailableDetail(trains: 1)
        } else if established.isEmpty {
            if coverage.isScheduleOnly {
                kind = .scheduleOnly
                title = Copy.scheduleOnly
                detail = Copy.scheduleOnlyDetail(trains: 1)
            } else {
                kind = .unconfirmed
                title = Copy.unconfirmed
                detail = Copy.unconfirmedDetail(trains: 1)
            }
        } else {
            let primary: [JourneyCoverage.Feature] = [.delays, .position]
            let missing = primary.filter { !established.contains($0) }
            kind = missing.isEmpty ? .connected : .limited
            title = established.map(Copy.feature).joined(separator: Copy.featureSeparator)

            // Capability only. Nothing here says the train is reporting right now: this row can sit
            // on screen for minutes, and freshness belongs to the tracking screen's own words.
            var sentences = missing.map { feature in
                coverage[feature].support == .notProvided ? Copy.notProvided(feature) : Copy.notConfirmed(feature)
            }
            if coverage.limitationCodes.contains("regionalScope"), let scope = coverage.scopeName {
                sentences.append(Copy.scope(scope))
            }
            detail = sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }
    }

    /// Worth a line above Save. A single train's own row already says everything about itself.
    var isGap: Bool { kind != .connected }

    var accessibilityLabel: String { [title, detail].compactMap { $0 }.joined(separator: ". ") }
}

/// Coverage across every train that resolved, for the summary above Save.
struct JourneyCoverageSummary: Equatable {
    struct Notice: Equatable {
        let title: String
        let message: String
        /// Only a diagnosed outage is a warning; missing or unknown coverage stays neutral.
        let isOutage: Bool
    }

    let trains: [JourneyCoverageDisclosure]
    let detailsURL: URL

    init(resolution: JourneyPlanResolution) {
        let resolved = resolution.directions.flatMap(\.segments).filter { $0.trip != nil }
        trains = resolved.map { JourneyCoverageDisclosure(coverage: $0.coverage) }
        detailsURL = resolved.first?.coverage.detailsURL ?? JourneyCoverage.detailsURL
    }

    /// Nothing live is connected for any saved train, so the action is to save, not to track.
    var isScheduleOnly: Bool { !trains.isEmpty && trains.allSatisfy { $0.kind == .scheduleOnly } }

    var notice: Notice? {
        typealias Copy = JourneySearchCopy.Coverage
        let gaps = trains.filter(\.isGap)
        guard !gaps.isEmpty else { return nil }
        // One train with partial coverage: its own row names the gap. Don't say it twice.
        if trains.count == 1, trains[0].kind == .limited { return nil }

        let count = trains.count
        if gaps.count == count, let kind = gaps.first?.kind, gaps.allSatisfy({ $0.kind == kind }) {
            switch kind {
            case .unavailableNow:
                return Notice(title: Copy.unavailableNow, message: Copy.unavailableDetail(trains: count), isOutage: true)
            case .scheduleOnly:
                return Notice(title: Copy.scheduleOnly, message: Copy.scheduleOnlyDetail(trains: count), isOutage: false)
            case .unconfirmed:
                return Notice(title: Copy.unconfirmed, message: Copy.unconfirmedDetail(trains: count), isOutage: false)
            case .limited, .connected:
                break
            }
        }
        return Notice(
            title: Copy.varies,
            message: Copy.variesDetail(gaps: gaps.count, total: count),
            isOutage: false
        )
    }
}
