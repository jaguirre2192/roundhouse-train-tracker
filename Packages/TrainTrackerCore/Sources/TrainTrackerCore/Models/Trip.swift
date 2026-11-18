import Foundation

public struct StopTime: Identifiable, Codable, Hashable, Sendable {
    public let station: Station
    public let sequence: Int
    public let scheduledArrival: Date?
    public let scheduledDeparture: Date?
    public let expectedArrival: Date?
    public let expectedDeparture: Date?
    public let plannedPlatform: String?
    public let expectedPlatform: String?
    public let platformForecast: PlatformForecast?
    /// Whether the assignment is a track (Amtrak and most North American stations) or a
    /// platform. A gate is a different place and is never stored here.
    public let platformKind: PlatformKind?
    /// The live feed that reports this stop's assignment, for example "Amtraker". Nil for
    /// operator timetable and operator realtime sources that name themselves elsewhere.
    public let platformSource: String?
    /// A supplier may retain an older assignment while publishing fresh journey times.
    public let platformObservedAt: Date?
    public let isCancelled: Bool
    public let isPassed: Bool
    /// An explicit provider report of passage. Absent in older archives whose flags could
    /// be inferred from the timetable; those flags alone are not movement evidence.
    public let passageObservedAt: Date?
    /// An explicit arrival report, distinct from leaving a stop after its dwell.
    public let arrivalObservedAt: Date?

    public init(
        station: Station,
        sequence: Int,
        scheduledArrival: Date? = nil,
        scheduledDeparture: Date? = nil,
        expectedArrival: Date? = nil,
        expectedDeparture: Date? = nil,
        plannedPlatform: String? = nil,
        expectedPlatform: String? = nil,
        platformForecast: PlatformForecast? = nil,
        platformKind: PlatformKind? = nil,
        platformSource: String? = nil,
        platformObservedAt: Date? = nil,
        isCancelled: Bool = false,
        isPassed: Bool = false,
        passageObservedAt: Date? = nil,
        arrivalObservedAt: Date? = nil
    ) {
        self.station = station
        self.sequence = sequence
        self.scheduledArrival = scheduledArrival
        self.scheduledDeparture = scheduledDeparture
        self.expectedArrival = expectedArrival
        self.expectedDeparture = expectedDeparture
        self.plannedPlatform = plannedPlatform
        self.expectedPlatform = expectedPlatform
        self.platformForecast = platformForecast
        self.platformKind = platformKind
        self.platformSource = platformSource
        self.platformObservedAt = platformObservedAt
        self.isCancelled = isCancelled
        self.isPassed = isPassed
        self.passageObservedAt = passageObservedAt
        self.arrivalObservedAt = arrivalObservedAt
    }

    public var id: String { "\(station.id.rawValue)#\(sequence)" }

    public var hasConfirmedPassage: Bool {
        hasConfirmedPassage(at: .now)
    }

    public func hasConfirmedPassage(at date: Date) -> Bool {
        isPassed && Self.validObservation(passageObservedAt, at: date)
    }

    public func hasConfirmedArrival(at date: Date) -> Bool {
        Self.validObservation(arrivalObservedAt, at: date) || hasConfirmedPassage(at: date)
    }

    private static func validObservation(_ observation: Date?, at date: Date) -> Bool {
        guard let observation else { return false }
        return observation.timeIntervalSinceReferenceDate.isFinite
            && date.timeIntervalSinceReferenceDate.isFinite && observation <= date.addingTimeInterval(120)
    }

    public func with(platformKind: PlatformKind?) -> StopTime {
        StopTime(
            station: station, sequence: sequence,
            scheduledArrival: scheduledArrival, scheduledDeparture: scheduledDeparture,
            expectedArrival: expectedArrival, expectedDeparture: expectedDeparture,
            plannedPlatform: plannedPlatform, expectedPlatform: expectedPlatform,
            platformForecast: platformForecast, platformKind: platformKind,
            platformSource: platformSource, platformObservedAt: platformObservedAt,
            isCancelled: isCancelled, isPassed: isPassed,
            passageObservedAt: passageObservedAt, arrivalObservedAt: arrivalObservedAt
        )
    }

    public var delayMinutes: Int? {
        let scheduled = scheduledDeparture ?? scheduledArrival
        let expected = expectedDeparture ?? expectedArrival
        guard let scheduled, let expected else { return nil }
        return Int(expected.timeIntervalSince(scheduled) / 60.0)
    }

    /// "Track" or "Platform", matching how the station signs the assignment.
    public var platformNoun: String {
        platformKind == .track ? "Track" : "Platform"
    }

    public func platformSummary(at date: Date = .now) -> String {
        platformGuidance(at: date).summaryText(noun: platformNoun, source: platformSource)
    }

    public var displayPlatform: String? {
        expectedPlatform ?? plannedPlatform
    }

    public var didPlatformChange: Bool {
        guard let plannedPlatform, let expectedPlatform else { return false }
        return plannedPlatform != expectedPlatform
    }

    public func platformGuidance(at date: Date = .now) -> PlatformGuidance {
        if let expected = expectedPlatform?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty {
            let planned = plannedPlatform?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .official(
                platform: expected,
                source: .current,
                changed: planned?.isEmpty == false && planned != expected
            )
        }
        if let planned = plannedPlatform?.trimmingCharacters(in: .whitespacesAndNewlines),
           !planned.isEmpty {
            return .official(platform: planned, source: .scheduled, changed: false)
        }
        guard let platformForecast, date < platformForecast.expiresAt else { return .unavailable }
        if platformForecast.state == .likelyPlatform,
           let platform = platformForecast.likelyPlatform?.trimmingCharacters(in: .whitespacesAndNewlines),
           !platform.isEmpty {
            return .likelyPlatform(
                platform: platform,
                zoneLabel: platformForecast.zone.label,
                confidence: platformForecast.confidence,
                explanation: platformForecast.explanation
            )
        }
        return .positioning(
            zoneLabel: platformForecast.zone.label,
            platforms: platformForecast.zone.platforms,
            confidence: platformForecast.confidence,
            explanation: platformForecast.explanation
        )
    }
}

public struct TrainTrip: Identifiable, Codable, Hashable, Sendable {
    public let id: RailIdentifier
    public let source: String
    public let serviceDate: Date
    public let operatorName: String
    public let product: String
    public let headsign: String
    public let stopTimes: [StopTime]
    public let routeGeometry: RouteGeometry?
    public let positions: [VehiclePosition]
    public let alerts: [RailAlert]
    public let capabilities: RealtimeCapabilities
    /// When the source timetable was fetched, which may precede a retained snapshot response.
    public let sourceFetchedAt: Date?

    public init(
        id: RailIdentifier,
        source: String,
        serviceDate: Date,
        operatorName: String,
        product: String,
        headsign: String,
        stopTimes: [StopTime],
        routeGeometry: RouteGeometry? = nil,
        positions: [VehiclePosition] = [],
        alerts: [RailAlert] = [],
        capabilities: RealtimeCapabilities,
        sourceFetchedAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.serviceDate = serviceDate
        self.operatorName = operatorName
        self.product = product
        self.headsign = headsign
        let ordered = stopTimes.sorted { $0.sequence < $1.sequence }
        // Amtrak stations sign tracks. Some feeds (Transitous) and trips saved by earlier
        // versions don't say so, so an Amtrak-operated trip always reads "Track".
        self.stopTimes = Self.isAmtrakOperated(id: id, source: source, operatorName: operatorName)
            ? ordered.map { $0.platformKind == .track ? $0 : $0.with(platformKind: .track) }
            : ordered
        self.routeGeometry = routeGeometry
        self.positions = positions
        self.alerts = alerts
        self.capabilities = capabilities
        self.sourceFetchedAt = sourceFetchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, serviceDate, operatorName, product, headsign, stopTimes
        case routeGeometry, positions, alerts, capabilities, sourceFetchedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(RailIdentifier.self, forKey: .id),
            source: values.decode(String.self, forKey: .source),
            serviceDate: values.decode(Date.self, forKey: .serviceDate),
            operatorName: values.decode(String.self, forKey: .operatorName),
            product: values.decode(String.self, forKey: .product),
            headsign: values.decode(String.self, forKey: .headsign),
            stopTimes: values.decode([StopTime].self, forKey: .stopTimes),
            routeGeometry: values.decodeIfPresent(RouteGeometry.self, forKey: .routeGeometry),
            positions: values.decode([VehiclePosition].self, forKey: .positions),
            alerts: values.decode([RailAlert].self, forKey: .alerts),
            capabilities: values.decode(RealtimeCapabilities.self, forKey: .capabilities),
            sourceFetchedAt: values.decodeIfPresent(Date.self, forKey: .sourceFetchedAt)
        )
    }

    /// Amtrak directly (Amtraker) or an Amtrak train carried by another feed.
    public static func isAmtrakOperated(id: RailIdentifier, source: String, operatorName: String) -> Bool {
        source == "amtraker"
            || operatorName.range(of: "Amtrak", options: .caseInsensitive) != nil
            || id.rawValue.range(of: "us-Amtrak", options: .caseInsensitive) != nil
    }

    public var origin: Station? { stopTimes.first?.station }
    public var destination: Station? { stopTimes.last?.station }
    public var nextStop: StopTime? { stopTimes.first { !$0.hasConfirmedPassage } }
    public var isComplete: Bool {
        stopTimes.last.map { !$0.isCancelled && $0.hasConfirmedArrival(at: .now) } == true
    }
    public var isCancelled: Bool { stopTimes.allSatisfy(\.isCancelled) }
    public var currentDelayMinutes: Int {
        nextStop?.delayMinutes ?? stopTimes.last?.delayMinutes ?? 0
    }
}
