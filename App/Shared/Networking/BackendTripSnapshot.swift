import Foundation
import TrainTrackerCore

struct BackendTripSnapshot: Decodable, Sendable {
    struct Stop: Decodable, Sendable {
        struct Forecast: Decodable, Sendable {
            struct Zone: Decodable, Sendable {
                let id: String
                let label: String
                let platforms: [String]
                let probability: Double
            }

            struct Candidate: Decodable, Sendable {
                let platform: String
                let probability: Double
                let observationCount: Int
            }

            let state: PlatformForecast.State
            let zone: Zone
            let candidates: [Candidate]
            let likelyPlatform: String?
            let confidence: PlatformForecast.Confidence
            let evidenceCount: Int
            let explanation: String
            let horizon: PlatformForecast.Horizon
            let modelVersion: String
            let timetablePeriod: String
            let stationMapVersion: String
            let generatedAt: String
            let expiresAt: String
        }

        let stationId: String
        let stationName: String
        var timeZoneIdentifier: String? = nil
        let countryCode: String
        let latitude: Double?
        let longitude: Double?
        let sequence: Int
        let scheduledArrival: String?
        let scheduledDeparture: String?
        let expectedArrival: String?
        let expectedDeparture: String?
        let plannedPlatform: String?
        let expectedPlatform: String?
        let platformSource: String?
        var platformObservedAt: String? = nil
        let cancelled: Bool
        let passed: Bool
        let passageObservedAt: String?
        let arrivalObservedAt: String?
        let platformForecast: Forecast?
    }

    struct Position: Decodable, Sendable {
        let latitude: Double
        let longitude: Double
        let heading: Double?
        let source: String
        let confidence: Double
        let asOf: String
        var timestampBasis: String? = nil
    }

    struct Geometry: Decodable, Sendable {
        struct Segment: Decodable, Sendable {
            let encodedPolyline: String
            let precision: Int
            let pointCount: Int
        }

        let source: String
        let segments: [Segment]
    }

    let id: String
    let source: String
    let serviceDate: String
    let operatorName: String
    let product: String
    let headsign: String
    let fetchedAt: String
    let stops: [Stop]
    let routeGeometry: Geometry?
    let positions: [Position]?

    var hasValidWireDates: Bool {
        guard WireDate.date(from: serviceDate) != nil, WireDate.date(from: fetchedAt) != nil else {
            return false
        }
        let stopsAreValid = stops.allSatisfy { stop in
            Self.isValidWireDate(stop.scheduledArrival)
                && Self.isValidWireDate(stop.scheduledDeparture)
                && Self.isValidWireDate(stop.expectedArrival)
                && Self.isValidWireDate(stop.expectedDeparture)
                && Self.isValidWireDate(stop.passageObservedAt)
                && Self.isValidWireDate(stop.arrivalObservedAt)
                && Self.isValidWireDate(stop.platformObservedAt)
                && Self.isValidWireDate(stop.platformForecast?.generatedAt)
                && Self.isValidWireDate(stop.platformForecast?.expiresAt)
        }
        let positionsAreValid = positions?.allSatisfy { WireDate.date(from: $0.asOf) != nil } ?? true
        return stopsAreValid && positionsAreValid
    }

    var trip: TrainTrip {
        let fetched = Self.parse(fetchedAt)
        let mappedStops = stops.map { Self.stop($0, tripSource: source, fetched: fetched) }
        let hasPlatforms = mappedStops.contains {
            $0.plannedPlatform != nil || $0.expectedPlatform != nil
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: id),
            source: source,
            serviceDate: Self.dateOnly(serviceDate) ?? .now,
            operatorName: operatorName,
            product: product,
            headsign: headsign,
            stopTimes: mappedStops,
            routeGeometry: Self.geometry(routeGeometry),
            positions: Self.positions(self) ?? [],
            capabilities: RealtimeCapabilities(
                hasPositions: positions?.isEmpty == false,
                hasPlatforms: hasPlatforms,
                hasRealtimeDelays: hasRealtimeDelays,
                hasAlerts: false,
                granularity: .perStop
            ),
            sourceFetchedAt: source == "srbijavoz" ? WireDate.date(from: fetchedAt) : nil
        )
    }

    func merging(into trip: TrainTrip) -> TrainTrip {
        let fetched = Self.parse(fetchedAt)
        let savedByStation = Dictionary(grouping: trip.stopTimes, by: { $0.station.id.rawValue })
        let currentByStation = Dictionary(grouping: stops, by: \.stationId)
        // The snapshot owns route membership and call order. Sequence numbers can move when
        // a call is added or removed, and one station can occur more than once on a route.
        let mergedStops = stops.map { update in
            let candidates = savedByStation[update.stationId] ?? []
            let stop = Self.previousCall(
                for: update, candidates: candidates,
                isUniqueCurrentStation: currentByStation[update.stationId]?.count == 1
            )
            // A live-only feed (Amtraker) has no timetable assignment to fall back on. Carrying an
            // earlier value forward would show a cleared track as an operator timetable value.
            let liveOnlySource = Self.isLiveOnlyPlatformSource(update.platformSource ?? stop?.platformSource, tripSource: source)
            return StopTime(
                station: Self.refreshedStation(update, saved: candidates.first?.station),
                sequence: update.sequence,
                scheduledArrival: Self.parse(update.scheduledArrival) ?? stop?.scheduledArrival,
                scheduledDeparture: Self.parse(update.scheduledDeparture) ?? stop?.scheduledDeparture,
                expectedArrival: Self.parse(update.expectedArrival),
                expectedDeparture: Self.parse(update.expectedDeparture),
                plannedPlatform: liveOnlySource ? update.plannedPlatform : (update.plannedPlatform ?? stop?.plannedPlatform),
                expectedPlatform: update.expectedPlatform,
                platformForecast: Self.forecast(update.platformForecast) ?? stop?.platformForecast,
                platformKind: stop?.platformKind ?? Self.platformKind(tripSource: source),
                platformSource: update.platformSource ?? (source == "amtraker" ? "Amtraker" : nil),
                platformObservedAt: Self.assignmentDate(update, fetched: fetched),
                isCancelled: update.cancelled,
                isPassed: update.passed,
                passageObservedAt: Self.parse(update.passageObservedAt),
                arrivalObservedAt: Self.parse(update.arrivalObservedAt)
            )
        }
        let hasPlatforms = mergedStops.contains {
            $0.plannedPlatform != nil || $0.expectedPlatform != nil
        }
        return TrainTrip(
            id: trip.id,
            source: trip.source,
            serviceDate: trip.serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: mergedStops,
            routeGeometry: Self.geometry(routeGeometry) ?? trip.routeGeometry,
            positions: Self.positions(self) ?? trip.positions,
            alerts: trip.alerts,
            capabilities: RealtimeCapabilities(
                hasPositions: trip.capabilities.hasPositions || positions?.isEmpty == false,
                hasPlatforms: trip.capabilities.hasPlatforms || hasPlatforms,
                hasRealtimeDelays: hasRealtimeDelays,
                hasAlerts: trip.capabilities.hasAlerts,
                granularity: .perStop
            ),
            sourceFetchedAt: source == "srbijavoz" ? WireDate.date(from: fetchedAt) : trip.sourceFetchedAt
        )
    }

    private var hasRealtimeDelays: Bool {
        !["ekispert", "chepe", "srbijavoz"].contains(source)
    }

    private static func refreshedStation(_ update: Stop, saved: Station?) -> Station {
        guard let saved else { return stop(update).station }
        let country = update.countryCode.uppercased()
        let validCountry = Locale.Region.isoRegions.contains { $0.identifier == country }
        let location: GeoCoordinate
        if let latitude = update.latitude, let longitude = update.longitude,
           latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
           latitude != 0 || longitude != 0 {
            location = GeoCoordinate(latitude: latitude, longitude: longitude)
        } else {
            location = saved.location
        }
        return Station(
            id: saved.id, names: saved.names, codes: saved.codes, location: location,
            countryCode: validCountry ? country : saved.countryCode, operatorHints: saved.operatorHints,
            timeZoneIdentifier: validStationZone(update.timeZoneIdentifier) ?? saved.timeZoneIdentifier
        )
    }

    private static func previousCall(
        for update: Stop, candidates: [StopTime], isUniqueCurrentStation: Bool
    ) -> StopTime? {
        if candidates.count == 1, isUniqueCurrentStation { return candidates.first }
        let arrival = parse(update.scheduledArrival)
        let departure = parse(update.scheduledDeparture)
        guard arrival != nil || departure != nil else { return nil }
        let matches = candidates.filter {
            $0.scheduledArrival == arrival && $0.scheduledDeparture == departure
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Amtrak stations sign tracks; other providers sign platforms.
    static func platformKind(tripSource: String) -> PlatformKind {
        tripSource == "amtraker" ? .track : .platform
    }

    static func isLiveOnlyPlatformSource(_ platformSource: String?, tripSource: String) -> Bool {
        platformSource == "Amtraker" || tripSource == "amtraker"
    }

    private static func assignmentDate(_ value: Stop, fetched: Date?) -> Date? {
        guard value.expectedPlatform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        // A retained overlay carries its own time. A new current assignment with no more
        // precise observation is only as fresh as the provider snapshot that supplied it.
        return parse(value.platformObservedAt) ?? fetched
    }

    static func stop(_ value: Stop, tripSource: String = "", fetched: Date? = nil) -> StopTime {
        StopTime(
            station: Station(
                id: RailIdentifier(rawValue: value.stationId),
                names: [LocalizedStationName(value.stationName)],
                codes: [.sourceNative: RailIdentifier(rawValue: value.stationId).nativeID ?? value.stationId],
                location: GeoCoordinate(latitude: value.latitude ?? 0, longitude: value.longitude ?? 0),
                countryCode: value.countryCode, timeZoneIdentifier: validStationZone(value.timeZoneIdentifier)
            ),
            sequence: value.sequence,
            scheduledArrival: parse(value.scheduledArrival),
            scheduledDeparture: parse(value.scheduledDeparture),
            expectedArrival: parse(value.expectedArrival),
            expectedDeparture: parse(value.expectedDeparture),
            plannedPlatform: value.plannedPlatform,
            expectedPlatform: value.expectedPlatform,
            platformForecast: forecast(value.platformForecast),
            platformKind: platformKind(tripSource: tripSource),
            platformSource: value.platformSource ?? (tripSource == "amtraker" ? "Amtraker" : nil),
            platformObservedAt: assignmentDate(value, fetched: fetched),
            isCancelled: value.cancelled,
            isPassed: value.passed,
            passageObservedAt: parse(value.passageObservedAt),
            arrivalObservedAt: parse(value.arrivalObservedAt)
        )
    }

    private static func validStationZone(_ id: String?) -> String? {
        guard let id, TimeZone(identifier: id) != nil else { return nil }
        return id
    }

    private static func positions(_ snapshot: BackendTripSnapshot) -> [VehiclePosition]? {
        guard let values = snapshot.positions else { return nil }
        return values.compactMap { value in
            guard let asOf = parse(value.asOf) else { return nil }
            return VehiclePosition(
                coordinate: GeoCoordinate(latitude: value.latitude, longitude: value.longitude),
                heading: value.heading,
                source: value.source == "inferred" ? .inferred : .real,
                confidence: value.confidence,
                asOf: asOf,
                timestampBasis: value.timestampBasis.flatMap(PositionTimestampBasis.init(rawValue:))
            )
        }
    }

    private static func geometry(_ value: Geometry?) -> RouteGeometry? {
        guard let value else { return nil }
        let segments = value.segments.compactMap { segment -> RouteGeometry.Segment? in
            guard !segment.encodedPolyline.isEmpty,
                  (0...7).contains(segment.precision),
                  (2...100_000).contains(segment.pointCount)
            else { return nil }
            return RouteGeometry.Segment(
                encodedPolyline: segment.encodedPolyline,
                precision: segment.precision,
                pointCount: segment.pointCount
            )
        }
        guard !segments.isEmpty else { return nil }
        return RouteGeometry(source: value.source, segments: segments)
    }

    private static func forecast(_ value: Stop.Forecast?) -> PlatformForecast? {
        guard let value,
              let generatedAt = parse(value.generatedAt),
              let expiresAt = parse(value.expiresAt)
        else { return nil }
        return PlatformForecast(
            state: value.state,
            zone: PlatformForecast.Zone(
                id: value.zone.id,
                label: value.zone.label,
                platforms: value.zone.platforms,
                probability: value.zone.probability
            ),
            candidates: value.candidates.map {
                PlatformForecast.Candidate(
                    platform: $0.platform,
                    probability: $0.probability,
                    observationCount: $0.observationCount
                )
            },
            likelyPlatform: value.likelyPlatform,
            confidence: value.confidence,
            evidenceCount: value.evidenceCount,
            explanation: value.explanation,
            horizon: value.horizon,
            modelVersion: value.modelVersion,
            timetablePeriod: value.timetablePeriod,
            stationMapVersion: value.stationMapVersion,
            generatedAt: generatedAt,
            expiresAt: expiresAt
        )
    }

    private static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func isValidWireDate(_ value: String?) -> Bool {
        guard let value else { return true }
        return WireDate.date(from: value) != nil
    }

    private static func dateOnly(_ value: String) -> Date? {
        let values = value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
}
