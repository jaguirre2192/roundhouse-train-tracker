import Foundation

/// The compact copy of the rider's next trains that the app writes to the App Group and the
/// Home Screen and Lock Screen widgets read. Pure Foundation so both sides compile it.
///
/// Only the selected leg's stops are kept (boarding to alighting), with station-local time
/// zones and the last successful check, so the widget can choose the next train, flip phases
/// at known times and describe freshness in the app's own words without network access.
public struct WidgetTripSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// How long an arrived train stays the widget's answer before the next one takes over.
    public static let arrivalGrace: TimeInterval = 30 * 60
    /// Upcoming or underway trains kept; one more than the medium widget shows, so the
    /// "Then" slot stays filled after the first train finishes without the app running.
    public static let upcomingLimit = 3

    public let schemaVersion: Int
    public let generatedAt: Date
    /// Ordered by departure. At most one finished train (the latest) precedes the rest.
    public let trains: [Train]

    public init(schemaVersion: Int = currentSchemaVersion, generatedAt: Date, trains: [Train]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.trains = trains.sorted(by: Train.departsBefore)
    }

    public static let empty = WidgetTripSnapshot(generatedAt: .distantPast, trains: [])

    public struct Stop: Codable, Equatable, Sendable {
        public let id: String?
        public let name: String
        /// A real letter code ("NYP"), never invented; nil when the station has none.
        public let code: String?
        public let timeZoneIdentifier: String?
        public let scheduledArrival: Date?
        public let scheduledDeparture: Date?
        public let expectedArrival: Date?
        public let expectedDeparture: Date?
        public let platform: String?
        public let platformKind: PlatformKind?
        public let isCancelled: Bool

        public init(
            name: String, id: String? = nil, code: String? = nil, timeZoneIdentifier: String? = nil,
            scheduledArrival: Date? = nil, scheduledDeparture: Date? = nil,
            expectedArrival: Date? = nil, expectedDeparture: Date? = nil,
            platform: String? = nil, platformKind: PlatformKind? = nil, isCancelled: Bool = false
        ) {
            self.id = id
            self.name = String(name.prefix(80))
            self.code = code.map { String($0.prefix(5)) }
            self.timeZoneIdentifier = timeZoneIdentifier.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
            self.scheduledArrival = scheduledArrival
            self.scheduledDeparture = scheduledDeparture
            self.expectedArrival = expectedArrival
            self.expectedDeparture = expectedDeparture
            let trimmed = platform?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.platform = trimmed.flatMap { $0.isEmpty ? nil : String($0.prefix(12)) }
            self.platformKind = platformKind
            self.isCancelled = isCancelled
        }

        /// The station's short label: its code, else its name.
        public var label: String { code ?? name }

        /// "Track" at Amtrak and most North American stations, otherwise "Platform".
        public var platformNoun: String { platformKind == .track ? "Track" : "Platform" }

        /// Departure evidence, falling back to arrival for a terminal call.
        public var departure: WidgetTime? {
            WidgetTime(expected: expectedDeparture ?? expectedArrival, scheduled: scheduledDeparture ?? scheduledArrival)
        }

        /// Arrival evidence, falling back to departure for an origin call.
        public var arrival: WidgetTime? {
            WidgetTime(expected: expectedArrival ?? expectedDeparture, scheduled: scheduledArrival ?? scheduledDeparture)
        }
    }

    public struct Train: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let serviceName: String
        public let boardingStationID: String?
        public let alightingStationID: String?
        /// The selected leg only, boarding first and alighting last.
        public let stops: [Stop]
        public let lastSuccessfulCheck: Date?
        public let lastRefreshFailed: Bool
        public let progressEvidence: WidgetProgressEvidence?

        public init(
            id: String, serviceName: String, boardingStationID: String? = nil, alightingStationID: String? = nil,
            stops: [Stop], lastSuccessfulCheck: Date? = nil, lastRefreshFailed: Bool = false,
            progressEvidence: WidgetProgressEvidence? = nil
        ) {
            self.id = id
            self.serviceName = String(serviceName.prefix(60))
            self.boardingStationID = boardingStationID
            self.alightingStationID = alightingStationID
            self.stops = Self.bounded(stops)
            self.lastSuccessfulCheck = lastSuccessfulCheck
            self.lastRefreshFailed = lastRefreshFailed
            self.progressEvidence = progressEvidence
        }

        public var boarding: Stop? { stops.first }
        public var alighting: Stop? { stops.count >= 2 ? stops.last : nil }
        public var departure: WidgetTime? { boarding?.departure }
        public var arrival: WidgetTime? { alighting?.arrival }

        /// Every selected call cancelled, or the rider's boarding or alighting call cancelled.
        public var isCancelled: Bool {
            guard let boarding, let alighting else { return false }
            return boarding.isCancelled || alighting.isCancelled
        }

        public var freshness: TripFreshness {
            TripFreshness(lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed)
        }

        /// The same route the Live Activity and Spotlight open: the trip with its selected leg.
        public var deepLinkURL: URL? {
            var components = URLComponents()
            components.scheme = "traintracker"
            components.host = "journey"
            var items = [URLQueryItem(name: "trip", value: id)]
            if let boardingStationID, let alightingStationID {
                items.append(URLQueryItem(name: "boarding", value: boardingStationID))
                items.append(URLQueryItem(name: "alighting", value: alightingStationID))
            }
            components.queryItems = items
            return components.url
        }

        static func departsBefore(_ lhs: Train, _ rhs: Train) -> Bool {
            switch (lhs.departure?.timetable, rhs.departure?.timetable) {
            case let (left?, right?): return left == right ? lhs.id < rhs.id : left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }

        /// Long-distance legs keep both ends and the stops nearest the start; the widget only
        /// ever needs the next call, so the middle of a very long leg is the safe part to drop.
        private static func bounded(_ stops: [Stop], limit: Int = 80) -> [Stop] {
            guard stops.count > limit, let last = stops.last else { return stops }
            return Array(stops.prefix(limit - 1)) + [last]
        }
    }
}

/// One timed event: the timetable time, and an estimate when a provider reported one.
public struct WidgetTime: Equatable, Sendable {
    public let expected: Date?
    public let scheduled: Date?

    init?(expected: Date?, scheduled: Date?) {
        let validExpected = expected.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
        let validScheduled = scheduled.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
        guard validExpected != nil || validScheduled != nil else { return nil }
        self.expected = validExpected
        self.scheduled = validScheduled
    }

    /// The time to plan around: the estimate when there is one.
    public var effective: Date { expected ?? scheduled ?? .distantPast }
    /// The printed time, used for ordering so a delay never reorders the rider's trains.
    public var timetable: Date { scheduled ?? expected ?? .distantPast }
    public var isEstimated: Bool { expected != nil }

    /// Whole minutes late (negative when early); nil without both times.
    public var delayMinutes: Int? {
        guard let expected, let scheduled else { return nil }
        return Int((expected.timeIntervalSince(scheduled) / 60).rounded(.down))
    }
}

public extension WidgetTripSnapshot.Train {
    /// Builds the widget copy of one tracked train's selected leg. Codes and time zones come
    /// from the app, which knows the rider's plans; nil boarding/alighting means the whole trip.
    init?(
        trip: TrainTrip,
        boardingStationID: RailIdentifier? = nil,
        alightingStationID: RailIdentifier? = nil,
        stationCodes: [RailIdentifier: String] = [:],
        stationTimeZones: [RailIdentifier: String] = [:],
        lastSuccessfulCheck: Date? = nil,
        lastRefreshFailed: Bool = false,
        referenceDate: Date = .now
    ) {
        let progress = RailJourneyProgress(
            trip: trip, referenceDate: referenceDate,
            boardingStationID: boardingStationID, alightingStationID: alightingStationID
        )
        guard progress.stops.count >= 2 else { return nil }
        let explicitLeg = boardingStationID != nil && alightingStationID != nil
        let amtrak = TrainTrip.isAmtrakOperated(id: trip.id, source: trip.source, operatorName: trip.operatorName)
        let stops = progress.stops.map { stop in
            WidgetTripSnapshot.Stop(
                name: stop.station.displayName, id: stop.id,
                code: stationCodes[stop.station.id],
                timeZoneIdentifier: stationTimeZones[stop.station.id],
                scheduledArrival: stop.scheduledArrival, scheduledDeparture: stop.scheduledDeparture,
                expectedArrival: stop.expectedArrival, expectedDeparture: stop.expectedDeparture,
                platform: stop.displayPlatform,
                platformKind: amtrak ? .track : stop.platformKind,
                isCancelled: stop.isCancelled
            )
        }
        self.init(
            id: trip.id.rawValue, serviceName: trip.product,
            // The deep link names a leg only when the rider chose one; otherwise the app picks.
            boardingStationID: explicitLeg ? progress.stops.first?.station.id.rawValue : nil,
            alightingStationID: explicitLeg ? progress.stops.last?.station.id.rawValue : nil,
            stops: stops, lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed,
            progressEvidence: WidgetProgressEvidence(progress: progress, at: referenceDate)
        )
    }
}

public extension WidgetTripSnapshot {
    /// Keeps what the widget can need until the app next writes: the latest finished train
    /// (for the ended state) and the next few that have not finished.
    static func make(trains: [Train], generatedAt: Date) -> WidgetTripSnapshot {
        // A train without a departure and arrival time cannot be placed in time or flipped.
        let ordered = trains.filter { $0.departure != nil && $0.arrival != nil }.sorted(by: Train.departsBefore)
        let finished = ordered.filter { WidgetTrainPhase.isFinished($0, at: generatedAt) }
        let open = ordered.filter { !WidgetTrainPhase.isFinished($0, at: generatedAt) }
        let latestFinished = finished.max { ($0.arrival?.effective ?? .distantPast) < ($1.arrival?.effective ?? .distantPast) }
        return WidgetTripSnapshot(
            generatedAt: generatedAt,
            trains: (latestFinished.map { [$0] } ?? []) + open.prefix(upcomingLimit)
        )
    }
}

/// Reads and writes the snapshot in the shared App Group container.
public struct WidgetSnapshotStore: Sendable {
    public static let appGroupIdentifier = "group.com.jorgeaguirre.TrainTracker"
    public static let widgetKind = "TrainTrackerNextTrain"
    static let filename = "WidgetTripSnapshot.json"

    public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public static var shared: WidgetSnapshotStore {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        return WidgetSnapshotStore(fileURL: container?.appending(path: filename, directoryHint: .notDirectory))
    }

    /// Nil when nothing has been written yet or the file is from an unknown schema.
    public func load() -> WidgetTripSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let snapshot = try? Self.decoder.decode(WidgetTripSnapshot.self, from: data),
              snapshot.schemaVersion == WidgetTripSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    /// Writes atomically. Returns false when the snapshot is unchanged, so callers can skip a
    /// timeline reload; `generatedAt` alone never counts as a change.
    @discardableResult
    public func save(_ snapshot: WidgetTripSnapshot) throws -> Bool {
        guard let fileURL else { return false }
        if let existing = load(), existing.trains == snapshot.trains { return false }
        try Self.encoder.encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
