import Foundation

/// A saved passenger leg, independent of the full route returned for a tracked train.
public struct JourneyPlanSegment: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case rail
        case walk
    }

    public let id: String
    public let kind: Kind
    public let from: RailPlace
    public let to: RailPlace
    /// Scheduled boarding and alighting times from the selected journey, never live estimates.
    public let departure: Date?
    public let arrival: Date?
    public let serviceName: String?
    public let resolvedTripID: RailIdentifier?
    public let unavailableReason: String?
    public let duration: TimeInterval?
    public let isStationChange: Bool

    public init(
        id: String,
        kind: Kind,
        from: RailPlace,
        to: RailPlace,
        departure: Date? = nil,
        arrival: Date? = nil,
        serviceName: String? = nil,
        resolvedTripID: RailIdentifier? = nil,
        unavailableReason: String? = nil,
        duration: TimeInterval? = nil,
        isStationChange: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.from = from
        self.to = to
        self.departure = departure
        self.arrival = arrival
        self.serviceName = serviceName
        self.resolvedTripID = resolvedTripID
        self.unavailableReason = unavailableReason
        self.duration = duration
        self.isStationChange = isStationChange
    }
}

public extension JourneyPlanDirection {
    /// A full train may be selected more than once, so its ID alone is not always a leg key.
    var ambiguousTripIDs: Set<RailIdentifier> {
        var seen: Set<RailIdentifier> = []
        var ambiguous: Set<RailIdentifier> = []
        for segment in selectedSegments ?? [] where segment.kind == .rail {
            guard let tripID = segment.resolvedTripID else { continue }
            if !seen.insert(tripID).inserted { ambiguous.insert(tripID) }
        }
        return ambiguous
    }

    /// Returns no inferred context for legacy plans or repeated uses of the same full train.
    func selectedSegment(for tripID: RailIdentifier) -> JourneyPlanSegment? {
        let matches = selectedSegments?.filter {
            $0.kind == .rail && $0.resolvedTripID == tripID
        } ?? []
        return matches.count == 1 ? matches.first : nil
    }
}
