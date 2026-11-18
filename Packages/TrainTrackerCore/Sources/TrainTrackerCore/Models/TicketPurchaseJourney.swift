import Foundation

/// A local matching aid for a retailer search, never a fare, reservation, or purchase receipt.
/// It deliberately excludes tracking tokens and account/payment data.
public struct TicketPurchaseJourney: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable {
        case unsupportedRoute, missingDetails, cancelled, invalidOrder
    }

    public struct Leg: Codable, Equatable, Sendable {
        public let origin: String
        public let destination: String
        public let train: String
        public let departure: Date
        public let arrival: Date
        public let departureTimeZone: String
        public let arrivalTimeZone: String
    }

    public struct Walk: Codable, Equatable, Sendable {
        public let origin: String
        public let destination: String
        public let duration: TimeInterval
        public let distance: Double?
        public let isStationChange: Bool

        public var distanceDescription: String? {
            guard let distance, distance.isFinite, distance >= 0 else { return nil }
            return Measurement(value: distance, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }

        public var durationDescription: String {
            guard duration.isFinite else { return "Duration unavailable" }
            let minutes = ceil(max(0, duration) / 60)
            guard minutes < Double(Int.max) else { return "Very long walk" }
            return "\(Int(minutes)) min"
        }
    }

    public enum Segment: Codable, Equatable, Sendable {
        case rail(Leg)
        case walk(Walk)
        case legacyTransfer(String)

        private enum CodingKeys: String, CodingKey {
            case kind
            case rail
            case walk
            case legacyTransfer
        }

        private enum Kind: String, Codable {
            case rail
            case walk
            case legacyTransfer
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .rail:
                self = .rail(try container.decode(Leg.self, forKey: .rail))
            case .walk:
                self = .walk(try container.decode(Walk.self, forKey: .walk))
            case .legacyTransfer:
                self = .legacyTransfer(try container.decode(String.self, forKey: .legacyTransfer))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .rail(leg):
                try container.encode(Kind.rail, forKey: .kind)
                try container.encode(leg, forKey: .rail)
            case let .walk(walk):
                try container.encode(Kind.walk, forKey: .kind)
                try container.encode(walk, forKey: .walk)
            case let .legacyTransfer(transfer):
                try container.encode(Kind.legacyTransfer, forKey: .kind)
                try container.encode(transfer, forKey: .legacyTransfer)
            }
        }
    }

    public struct Direction: Codable, Equatable, Sendable {
        public let fingerprint: String
        public let segments: [Segment]

        public var legs: [Leg] {
            segments.compactMap { if case let .rail(leg) = $0 { leg } else { nil } }
        }

        public var transfers: [String] {
            segments.compactMap { segment in
                switch segment {
                case let .walk(walk): Self.walkSummary(walk)
                case let .legacyTransfer(transfer): transfer
                case .rail: nil
                }
            }
        }

        fileprivate var scheduledStartTime: Date? {
            var leadingWalkDuration: TimeInterval = 0
            for segment in segments {
                switch segment {
                case let .walk(walk):
                    leadingWalkDuration += walk.duration
                    guard leadingWalkDuration.isFinite else { return nil }
                case .legacyTransfer:
                    continue
                case let .rail(leg):
                    return Self.adjusted(leg.departure, by: -leadingWalkDuration)
                }
            }
            return nil
        }

        fileprivate var scheduledEndTime: Date? {
            var trailingWalkDuration: TimeInterval = 0
            for segment in segments.reversed() {
                switch segment {
                case let .walk(walk):
                    trailingWalkDuration += walk.duration
                    guard trailingWalkDuration.isFinite else { return nil }
                case .legacyTransfer:
                    continue
                case let .rail(leg):
                    return Self.adjusted(leg.arrival, by: trailingWalkDuration)
                }
            }
            return nil
        }

        fileprivate init(option: JourneyOption) throws {
            var segments: [Segment] = []
            var previousRailArrival: Date?
            var pendingWalkDuration: TimeInterval = 0
            for segment in option.segments {
                switch segment {
                case let .walk(walk):
                    guard walk.from.countryCode.uppercased() == "US",
                          walk.to.countryCode.uppercased() == "US" else {
                        throw ValidationError.unsupportedRoute
                    }
                    guard walk.duration.isFinite, walk.duration >= 0,
                          !walk.from.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !walk.to.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ValidationError.missingDetails
                    }
                    segments.append(.walk(Walk(
                        origin: walk.from.displayName,
                        destination: walk.to.displayName,
                        duration: walk.duration,
                        distance: walk.distance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                        isStationChange: walk.isStationChange
                    )))
                    pendingWalkDuration += walk.duration
                    guard pendingWalkDuration.isFinite else { throw ValidationError.invalidOrder }
                case let .rail(rail):
                    let operatorName = rail.operatorName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard operatorName == "amtrak",
                          ([rail.from, rail.to] + rail.intermediateCalls).allSatisfy({
                              $0.place.countryCode.uppercased() == "US"
                          }) else { throw ValidationError.unsupportedRoute }
                    guard !rail.isCancelled, !rail.from.isCancelled, !rail.to.isCancelled else {
                        throw ValidationError.cancelled
                    }
                    guard let departure = rail.from.scheduledDeparture,
                          let arrival = rail.to.scheduledArrival,
                          departure.timeIntervalSince1970.isFinite, arrival.timeIntervalSince1970.isFinite,
                          TimeZone(identifier: rail.from.place.timeZoneIdentifier) != nil,
                          TimeZone(identifier: rail.to.place.timeZoneIdentifier) != nil,
                          rail.from.place.kind == .station, rail.to.place.kind == .station,
                          !rail.from.place.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !rail.to.place.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let number = rail.trainNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !number.isEmpty else { throw ValidationError.missingDetails }
                    let connectionIsPossible: Bool
                    if let previousRailArrival {
                        connectionIsPossible = Self.adjusted(previousRailArrival, by: pendingWalkDuration)
                            .map { $0 <= departure } ?? false
                    } else {
                        connectionIsPossible = true
                    }
                    guard arrival > departure, connectionIsPossible else {
                        throw ValidationError.invalidOrder
                    }
                    let leg = Leg(origin: rail.from.place.displayName, destination: rail.to.place.displayName,
                        train: "Amtrak \(number)", departure: departure, arrival: arrival,
                        departureTimeZone: rail.from.place.timeZoneIdentifier,
                        arrivalTimeZone: rail.to.place.timeZoneIdentifier)
                    segments.append(.rail(leg))
                    previousRailArrival = arrival
                    pendingWalkDuration = 0
                }
            }
            guard segments.contains(where: { if case .rail = $0 { true } else { false } }),
                  !option.fingerprint.isEmpty else { throw ValidationError.missingDetails }
            self.fingerprint = option.fingerprint
            self.segments = segments
        }

        private static func adjusted(_ date: Date, by interval: TimeInterval) -> Date? {
            guard interval.isFinite else { return nil }
            let adjusted = date.addingTimeInterval(interval)
            return adjusted.timeIntervalSinceReferenceDate.isFinite ? adjusted : nil
        }

        private enum CodingKeys: String, CodingKey {
            case fingerprint
            case segments
            case legs
            case transfers
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            if let segments = try container.decodeIfPresent([Segment].self, forKey: .segments) {
                self.segments = segments
            } else {
                let legacyLegs = try container.decodeIfPresent([Leg].self, forKey: .legs) ?? []
                let legacyTransfers = try container.decodeIfPresent([String].self, forKey: .transfers) ?? []
                self.segments = legacyLegs.map(Segment.rail)
                    + legacyTransfers.map(Segment.legacyTransfer)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fingerprint, forKey: .fingerprint)
            try container.encode(segments, forKey: .segments)
        }

        fileprivate static func walkSummary(_ walk: Walk) -> String {
            let stationChange = walk.isStationChange ? " · station change" : ""
            let distance = walk.distanceDescription.map { " · \($0)" } ?? ""
            return "Walk from \(walk.origin) to \(walk.destination) · \(walk.durationDescription)\(distance)\(stationChange)"
        }
    }

    public let outbound: Direction
    public let returnDirection: Direction?

    public init(outbound: JourneyOption, returnOption: JourneyOption?) throws {
        self.outbound = try Direction(option: outbound)
        returnDirection = try returnOption.map(Direction.init)
        if let returning = returnDirection {
            guard let arrival = self.outbound.scheduledEndTime,
                  let departure = returning.scheduledStartTime,
                  departure >= arrival else {
                throw ValidationError.invalidOrder
            }
        }
    }

    public var retailerURL: URL { URL(string: "https://www.omio.com/trains/united-states")! }
    public var selectionFingerprints: [String] { directions.map(\.fingerprint) }
    public var directions: [Direction] { [outbound, returnDirection].compactMap { $0 } }
    public var routeTitle: String {
        "\(outbound.legs.first?.origin ?? "") → \(outbound.legs.last?.destination ?? "")"
    }

    public func canSearch(at now: Date) -> Bool {
        !outbound.legs.isEmpty && directions.allSatisfy { direction in
            !direction.legs.isEmpty && direction.legs.allSatisfy {
                $0.departure > now && $0.arrival > $0.departure
                    && TimeZone(identifier: $0.departureTimeZone) != nil
                    && TimeZone(identifier: $0.arrivalTimeZone) != nil
            }
        }
    }

    public var summary: String {
        var sections = ["Journey to match on Omio — scheduled times, not a ticket or reservation"]
        for (index, direction) in directions.enumerated() {
            sections.append(index == 0 ? "Outbound" : "Return")
            for segment in direction.segments {
                switch segment {
                case let .rail(leg):
                    sections.append("\(leg.train)\n\(leg.origin) → \(leg.destination)\nDepart: \(Self.localDate(leg.departure, timeZone: leg.departureTimeZone))\nArrive: \(Self.localDate(leg.arrival, timeZone: leg.arrivalTimeZone))")
                case let .walk(walk):
                    sections.append(Direction.walkSummary(walk))
                case let .legacyTransfer(transfer):
                    sections.append(transfer)
                }
            }
        }
        sections.append("Select the matching stations, dates and trains on Omio. Choose passengers, class and discounts there; availability and fares may differ.")
        return sections.joined(separator: "\n\n")
    }

    public static func localDate(_ date: Date, timeZone: String) -> String {
        guard let zone = TimeZone(identifier: timeZone) else { return "Local time unavailable" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a zzz"
        return formatter.string(from: date)
    }
}
