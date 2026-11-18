import Foundation

public struct JourneySearchCriteria: Codable, Hashable, Sendable {
    public let originID: RailIdentifier
    public let destinationID: RailIdentifier
    public let requestedTime: Date
    public let timeZoneIdentifier: String
    public let arriveBy: Bool
    public let maximumTransfers: Int
    public let cursor: String?

    public init(
        originID: RailIdentifier,
        destinationID: RailIdentifier,
        requestedTime: Date,
        timeZoneIdentifier: String,
        arriveBy: Bool,
        maximumTransfers: Int,
        cursor: String?
    ) {
        self.originID = originID
        self.destinationID = destinationID
        self.requestedTime = requestedTime
        self.timeZoneIdentifier = timeZoneIdentifier
        self.arriveBy = arriveBy
        self.maximumTransfers = maximumTransfers
        self.cursor = cursor
    }
}

public struct JourneyCall: Codable, Hashable, Sendable {
    public let place: RailPlace
    public let city: RailPlace?
    public let scheduledArrival: Date?
    public let scheduledDeparture: Date?
    public let expectedArrival: Date?
    public let expectedDeparture: Date?
    public let plannedPlatform: String?
    public let expectedPlatform: String?
    public let isCancelled: Bool

    public init(
        place: RailPlace,
        city: RailPlace?,
        scheduledArrival: Date?,
        scheduledDeparture: Date?,
        expectedArrival: Date?,
        expectedDeparture: Date?,
        plannedPlatform: String?,
        expectedPlatform: String?,
        isCancelled: Bool
    ) {
        self.place = place
        self.city = city
        self.scheduledArrival = scheduledArrival
        self.scheduledDeparture = scheduledDeparture
        self.expectedArrival = expectedArrival
        self.expectedDeparture = expectedDeparture
        self.plannedPlatform = plannedPlatform
        self.expectedPlatform = expectedPlatform
        self.isCancelled = isCancelled
    }
}

public struct RailJourneySegment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let tripID: RailIdentifier?
    public let serviceDate: Date
    public let operatorName: String
    public let product: String
    public let trainNumber: String?
    public let trainName: String?
    public let from: JourneyCall
    public let to: JourneyCall
    public let intermediateCalls: [JourneyCall]
    public let isCancelled: Bool
    public let isRealtime: Bool
    public let isTrackable: Bool
    public let untrackableReason: String?

    public init(
        id: String,
        tripID: RailIdentifier?,
        serviceDate: Date,
        operatorName: String,
        product: String,
        trainNumber: String?,
        trainName: String?,
        from: JourneyCall,
        to: JourneyCall,
        intermediateCalls: [JourneyCall],
        isCancelled: Bool,
        isRealtime: Bool,
        isTrackable: Bool,
        untrackableReason: String?
    ) {
        self.id = id
        self.tripID = tripID
        self.serviceDate = serviceDate
        self.operatorName = operatorName
        self.product = product
        self.trainNumber = trainNumber
        self.trainName = trainName
        self.from = from
        self.to = to
        self.intermediateCalls = intermediateCalls
        self.isCancelled = isCancelled
        self.isRealtime = isRealtime
        self.isTrackable = isTrackable
        self.untrackableReason = untrackableReason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self = try Self(id: id, payloadFrom: container)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try encodePayload(to: &container)
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case id
        case tripID = "tripId"
        case serviceDate
        case operatorName
        case product
        case trainNumber
        case trainName
        case from
        case to
        case intermediateCalls
        case isCancelled
        case isRealtime
        case isTrackable
        case untrackableReason
    }

    fileprivate init(
        id: String,
        payloadFrom container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        self.init(
            id: id,
            tripID: try container.decodeIfPresent(RailIdentifier.self, forKey: .tripID),
            serviceDate: try container.decode(Date.self, forKey: .serviceDate),
            operatorName: try container.decode(String.self, forKey: .operatorName),
            product: try container.decode(String.self, forKey: .product),
            trainNumber: try container.decodeIfPresent(String.self, forKey: .trainNumber),
            trainName: try container.decodeIfPresent(String.self, forKey: .trainName),
            from: try container.decode(JourneyCall.self, forKey: .from),
            to: try container.decode(JourneyCall.self, forKey: .to),
            intermediateCalls: try container.decode([JourneyCall].self, forKey: .intermediateCalls),
            isCancelled: try container.decode(Bool.self, forKey: .isCancelled),
            isRealtime: try container.decode(Bool.self, forKey: .isRealtime),
            isTrackable: try container.decode(Bool.self, forKey: .isTrackable),
            untrackableReason: try container.decodeIfPresent(String.self, forKey: .untrackableReason)
        )
    }

    fileprivate func encodePayload(
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encodeIfPresent(tripID, forKey: .tripID)
        try container.encode(serviceDate, forKey: .serviceDate)
        try container.encode(operatorName, forKey: .operatorName)
        try container.encode(product, forKey: .product)
        try container.encodeIfPresent(trainNumber, forKey: .trainNumber)
        try container.encodeIfPresent(trainName, forKey: .trainName)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(intermediateCalls, forKey: .intermediateCalls)
        try container.encode(isCancelled, forKey: .isCancelled)
        try container.encode(isRealtime, forKey: .isRealtime)
        try container.encode(isTrackable, forKey: .isTrackable)
        try container.encodeIfPresent(untrackableReason, forKey: .untrackableReason)
    }
}

public struct WalkJourneySegment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let from: RailPlace
    public let to: RailPlace
    public let duration: TimeInterval
    public let distance: Double?
    public let isStationChange: Bool

    public init(
        id: String,
        from: RailPlace,
        to: RailPlace,
        duration: TimeInterval,
        distance: Double?,
        isStationChange: Bool
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.duration = duration
        self.distance = distance
        self.isStationChange = isStationChange
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self = try Self(id: id, payloadFrom: container)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try encodePayload(to: &container)
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case id
        case from
        case to
        case duration
        case distance
        case isStationChange
    }

    fileprivate init(
        id: String,
        payloadFrom container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        self.init(
            id: id,
            from: try container.decode(RailPlace.self, forKey: .from),
            to: try container.decode(RailPlace.self, forKey: .to),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            distance: try container.decodeIfPresent(Double.self, forKey: .distance),
            isStationChange: try container.decode(Bool.self, forKey: .isStationChange)
        )
    }

    fileprivate func encodePayload(
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(distance, forKey: .distance)
        try container.encode(isStationChange, forKey: .isStationChange)
    }
}

public enum JourneySegment: Identifiable, Codable, Hashable, Sendable {
    case rail(RailJourneySegment)
    case walk(WalkJourneySegment)

    public var id: String {
        switch self {
        case let .rail(segment): segment.id
        case let .walk(segment): segment.id
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)

        switch try container.decode(Kind.self, forKey: .kind) {
        case .rail:
            guard container.contains(.walk), try container.decodeNil(forKey: .walk) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .walk,
                    in: container,
                    debugDescription: "Rail journey segments require a null walk value."
                )
            }
            let payload = try container.nestedContainer(
                keyedBy: RailJourneySegment.CodingKeys.self,
                forKey: .rail
            )
            self = .rail(try RailJourneySegment(id: id, payloadFrom: payload))
        case .walk:
            guard container.contains(.rail), try container.decodeNil(forKey: .rail) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rail,
                    in: container,
                    debugDescription: "Walk journey segments require a null rail value."
                )
            }
            let payload = try container.nestedContainer(
                keyedBy: WalkJourneySegment.CodingKeys.self,
                forKey: .walk
            )
            self = .walk(try WalkJourneySegment(id: id, payloadFrom: payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)

        switch self {
        case let .rail(segment):
            try container.encode(Kind.rail, forKey: .kind)
            var payload = container.nestedContainer(
                keyedBy: RailJourneySegment.CodingKeys.self,
                forKey: .rail
            )
            try segment.encodePayload(to: &payload)
            try container.encodeNil(forKey: .walk)
        case let .walk(segment):
            try container.encode(Kind.walk, forKey: .kind)
            try container.encodeNil(forKey: .rail)
            var payload = container.nestedContainer(
                keyedBy: WalkJourneySegment.CodingKeys.self,
                forKey: .walk
            )
            try segment.encodePayload(to: &payload)
        }
    }

    private enum Kind: String, Codable {
        case rail
        case walk
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case rail
        case walk
    }
}

public enum JourneyBadge: String, Codable, Hashable, Sendable {
    case direct
    case fastest
    case fewestChanges
}

public struct JourneyTrackability: Codable, Hashable, Sendable {
    public let trackableRailSegments: Int
    public let totalRailSegments: Int

    public init(trackableRailSegments: Int, totalRailSegments: Int) {
        self.trackableRailSegments = trackableRailSegments
        self.totalRailSegments = totalRailSegments
    }
}

public struct JourneyOption: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let fingerprint: String
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    public let transferCount: Int
    public let segments: [JourneySegment]
    public let badges: [JourneyBadge]
    public let trackability: JourneyTrackability
    public let realtimeFreshness: Date?
    public let attributions: [String]
    public let trackingToken: String

    public init(
        id: String,
        fingerprint: String,
        startTime: Date,
        endTime: Date,
        duration: TimeInterval,
        transferCount: Int,
        segments: [JourneySegment],
        badges: [JourneyBadge],
        trackability: JourneyTrackability,
        realtimeFreshness: Date?,
        attributions: [String],
        trackingToken: String
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.transferCount = transferCount
        self.segments = segments
        self.badges = badges
        self.trackability = trackability
        self.realtimeFreshness = realtimeFreshness
        self.attributions = attributions
        self.trackingToken = trackingToken
    }
}

public struct JourneySearchPage: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let expiresAt: Date
    public let options: [JourneyOption]
    public let previousCursor: String?
    public let nextCursor: String?
    public let warnings: [String]
    public let attributions: [String]

    public init(
        generatedAt: Date,
        expiresAt: Date,
        options: [JourneyOption],
        previousCursor: String?,
        nextCursor: String?,
        warnings: [String],
        attributions: [String]
    ) {
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.options = options
        self.previousCursor = previousCursor
        self.nextCursor = nextCursor
        self.warnings = warnings
        self.attributions = attributions
    }
}
