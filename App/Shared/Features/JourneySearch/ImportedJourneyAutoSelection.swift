import Foundation
import TrainTrackerCore

/// A one-use preference for opening review. It never resolves or saves a journey.
struct ImportedJourneyAutoSelection: Equatable, Sendable {
    enum Decision: Equatable {
        case review(JourneyOption)
        case choose(Reason)
    }

    enum Reason: Equatable {
        case noMatch, ambiguous, connection, cancelled, notFullyTrackable

        var message: String {
            switch self {
            case .noMatch: "We couldn't confirm a train at this departure time. Choose a departure to review."
            case .ambiguous: "More than one train matches these details. Choose the right departure."
            case .connection: "The matching journey includes a connection. Choose a journey to review its trains."
            case .cancelled: "The matching train is marked canceled. Choose another departure."
            case .notFullyTrackable: "The matching journey can't be tracked in full. Choose a journey to review."
            }
        }
    }

    /// Without a service number, only an exact departure between the matched stations counts.
    static let unnumberedTolerance: TimeInterval = 60

    let trainNumber: String?
    let departureTime: Date
    let originID: RailIdentifier?
    let destinationID: RailIdentifier?

    init?(trainNumber: String?, departureTime: String?) {
        guard let departureTime, departureTime.contains("T") else { return nil }
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: departureTime)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: departureTime)
        }
        guard let date, JourneyImportedTrainPreference.isAvailable(trainNumber) else { return nil }
        self.trainNumber = trainNumber
        self.departureTime = date
        originID = nil
        destinationID = nil
    }

    /// A numbered service matches within 15 minutes. An unnumbered ticket needs both resolved
    /// stations and a departure within one minute, so a nearby different train cannot match.
    init?(trainNumber: String?, departure: Date?, origin: RailPlace?, destination: RailPlace?) {
        guard let departure else { return nil }
        if JourneyImportedTrainPreference.isAvailable(trainNumber) {
            self.trainNumber = trainNumber
            originID = nil
            destinationID = nil
        } else {
            guard let origin, let destination, origin.kind == .station, destination.kind == .station,
                  origin.id != destination.id else { return nil }
            self.trainNumber = nil
            originID = origin.id
            destinationID = destination.id
        }
        departureTime = departure
    }

    func decision(in options: [JourneyOption]) -> Decision {
        let matching = options.filter(matches)
        guard let first = matching.first else { return .choose(.noMatch) }
        guard !first.fingerprint.isEmpty,
              Set(matching.map(\.fingerprint)).count == 1 else { return .choose(.ambiguous) }

        // Duplicate provider rows count as one fingerprint only when every copy
        // passes the same safeguards; a conflicting cancellation must stay visible.
        for option in matching {
            guard option.transferCount == 0, option.segments.count == 1,
                  case let .rail(rail) = option.segments[0] else { return .choose(.connection) }
            guard !rail.isCancelled, !rail.from.isCancelled, !rail.to.isCancelled,
                  !rail.intermediateCalls.contains(where: \.isCancelled) else { return .choose(.cancelled) }
            guard rail.isTrackable, let tripID = rail.tripID, !tripID.rawValue.isEmpty,
                  option.trackability.totalRailSegments == 1,
                  option.trackability.trackableRailSegments == 1,
                  !option.trackingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .choose(.notFullyTrackable) }
        }
        return .review(first)
    }

    private func matches(_ option: JourneyOption) -> Bool {
        let rails = option.segments.compactMap(\.rail)
        guard let firstRail = rails.first,
              let scheduledDeparture = firstRail.from.scheduledDeparture else { return false }
        if let trainNumber {
            return JourneyImportedTrainPreference.matches(option, trainNumber: trainNumber)
                && abs(scheduledDeparture.timeIntervalSince(departureTime)) <= 15 * 60
        }
        guard let originID, let destinationID, let lastRail = rails.last else { return false }
        return abs(scheduledDeparture.timeIntervalSince(departureTime)) <= Self.unnumberedTolerance
            && (firstRail.from.place.id == originID || firstRail.from.city?.id == originID)
            && (lastRail.to.place.id == destinationID || lastRail.to.city?.id == destinationID)
    }
}

private extension JourneySegment {
    var rail: RailJourneySegment? {
        guard case let .rail(value) = self else { return nil }
        return value
    }
}
