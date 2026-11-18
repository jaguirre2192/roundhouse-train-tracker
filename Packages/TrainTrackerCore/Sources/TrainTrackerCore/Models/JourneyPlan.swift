import Foundation

public struct JourneyPlanDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: RailPlace
    public let destination: RailPlace
    public let outbound: JourneyOption
    public let returnOption: JourneyOption?
    public let calendarSource: CalendarJourneySource?

    public init(
        id: UUID,
        origin: RailPlace,
        destination: RailPlace,
        outbound: JourneyOption,
        returnOption: JourneyOption?,
        calendarSource: CalendarJourneySource? = nil
    ) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.outbound = outbound
        self.returnOption = returnOption
        self.calendarSource = calendarSource
    }
}

public struct JourneyPlanDirection: Codable, Hashable, Sendable {
    public let fingerprint: String
    public let departure: Date
    public let arrival: Date
    public let childTripIDs: [RailIdentifier]
    /// The passenger's selected legs, in journey order. Older saved plans have no context.
    public let selectedSegments: [JourneyPlanSegment]?

    public init(
        fingerprint: String,
        departure: Date,
        arrival: Date,
        childTripIDs: [RailIdentifier],
        selectedSegments: [JourneyPlanSegment]? = nil
    ) {
        self.fingerprint = fingerprint
        self.departure = departure
        self.arrival = arrival
        self.childTripIDs = childTripIDs
        self.selectedSegments = selectedSegments
    }
}

public struct TrackedJourneyPlan: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let origin: RailPlace
    public let destination: RailPlace
    public let outbound: JourneyPlanDirection
    public let returnDirection: JourneyPlanDirection?
    public let preExistingChildTripIDs: Set<RailIdentifier>
    public let calendarSource: CalendarJourneySource?

    public init(
        id: UUID,
        createdAt: Date,
        origin: RailPlace,
        destination: RailPlace,
        outbound: JourneyPlanDirection,
        returnDirection: JourneyPlanDirection?,
        preExistingChildTripIDs: Set<RailIdentifier>,
        calendarSource: CalendarJourneySource? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.origin = origin
        self.destination = destination
        self.outbound = outbound
        self.returnDirection = returnDirection
        self.preExistingChildTripIDs = preExistingChildTripIDs
        self.calendarSource = calendarSource
    }
}
