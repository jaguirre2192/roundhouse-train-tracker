import Foundation

enum AmtrakerMapper {
    static let capabilities = RealtimeCapabilities(
        hasPositions: true,
        hasPlatforms: true,
        hasRealtimeDelays: true,
        hasAlerts: true,
        granularity: .perStop
    )

    static func station(_ value: AmtrakerStationDTO) -> Station {
        Station(
            id: stationID(value.code),
            names: [LocalizedStationName(value.name, localeIdentifier: "en_US")],
            codes: [.sourceNative: value.code],
            location: GeoCoordinate(
                latitude: value.lat ?? 0,
                longitude: value.lon ?? 0
            ),
            countryCode: "US",
            operatorHints: ["Amtrak"]
        )
    }

    static func trip(
        _ value: AmtrakerTrainDTO,
        serviceDate: Date,
        stations: [String: AmtrakerStationDTO],
        now: Date
    ) -> TrainTrip {
        let tripID = RailIdentifier(region: "us", source: "amtraker", nativeID: value.trainID)
        let stopTimes = value.stations.enumerated().map { index, stop in
            let metadata = stations[stop.code]
            let canonicalStation = Station(
                id: stationID(stop.code),
                names: [LocalizedStationName(stop.name, localeIdentifier: "en_US")],
                codes: [.sourceNative: stop.code],
                location: GeoCoordinate(
                    latitude: metadata?.lat ?? 0,
                    longitude: metadata?.lon ?? 0
                ),
                countryCode: "US",
                operatorHints: ["Amtrak"]
            )
            let expectedDeparture = RailDateParser.parse(stop.dep)
            let expectedArrival = RailDateParser.parse(stop.arr)
            let hasPassed = stop.status?.localizedCaseInsensitiveCompare("Departed") == .orderedSame
                || (expectedDeparture ?? expectedArrival).map { $0 < now && stop.status != "Enroute" } == true

            return StopTime(
                station: canonicalStation,
                sequence: index + 1,
                scheduledArrival: RailDateParser.parse(stop.schArr),
                scheduledDeparture: RailDateParser.parse(stop.schDep),
                expectedArrival: expectedArrival,
                expectedDeparture: expectedDeparture,
                plannedPlatform: normalized(stop.platform),
                expectedPlatform: normalized(stop.platform),
                // Amtraker's value is a track, reported only when its live source has one.
                platformKind: .track,
                platformSource: "Amtraker",
                isCancelled: stop.status?.localizedCaseInsensitiveContains("cancel") == true,
                isPassed: hasPassed
            )
        }

        let product = [value.routeName, value.trainNum]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return TrainTrip(
            id: tripID,
            source: "amtraker",
            serviceDate: serviceDate,
            operatorName: value.provider ?? "Amtrak",
            product: product,
            headsign: value.destName ?? stopTimes.last?.station.displayName ?? "",
            stopTimes: stopTimes,
            positions: position(value, now: now).map { [$0] } ?? [],
            alerts: alerts(value, tripID: tripID),
            capabilities: capabilities
        )
    }

    static func boardServiceDate(
        _ value: AmtrakerStopDTO,
        direction: BoardDirection,
        fallback: Date
    ) -> Date {
        let event = switch direction {
        case .arrivals: value.arr ?? value.schArr
        case .departures: value.dep ?? value.schDep
        }
        guard let event, let parsed = dateOnlyPrefix(event)
        else { return fallback }
        return parsed
    }

    /// Allowed clock skew before a provider timestamp counts as implausibly in the future.
    static let futureTimestampTolerance: TimeInterval = 2 * 60

    /// A position needs a real, plausible observation time: GPS with a missing, malformed or
    /// future timestamp has unknown age and must never be shown as fresh.
    static func position(_ value: AmtrakerTrainDTO, now: Date) -> VehiclePosition? {
        guard let latitude = value.lat, let longitude = value.lon,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0),
              let asOf = RailDateParser.parse(value.lastValTS) ?? RailDateParser.parse(value.updatedAt),
              asOf.timeIntervalSince(now) <= futureTimestampTolerance else { return nil }
        let age = max(now.timeIntervalSince(asOf), 0)
        let confidence = switch age {
        case ..<300: 1.0
        case ..<900: 0.8
        default: 0.5
        }
        return VehiclePosition(
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            heading: heading(value.heading),
            source: .real,
            confidence: confidence,
            asOf: asOf
        )
    }

    static func alerts(_ value: AmtrakerTrainDTO, tripID: RailIdentifier) -> [RailAlert] {
        (value.alerts ?? []).enumerated().map { index, alert in
            RailAlert(
                id: RailIdentifier(
                    region: "us",
                    source: "amtraker",
                    nativeID: "\(value.trainID)-alert-\(index)"
                ),
                severity: .information,
                affectedTripIDs: [tripID],
                message: alert.message
            )
        }
    }

    private static func stationID(_ code: String) -> RailIdentifier {
        RailIdentifier(region: "us", source: "amtraker", nativeID: code)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func dateOnlyPrefix(_ value: String) -> Date? {
        let date = String(value.prefix(10))
        let values = date.split(separator: "-").compactMap { Int($0) }
        guard date.count == 10, values.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let expected = DateComponents(year: values[0], month: values[1], day: values[2])
        guard let result = calendar.date(from: expected) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: result)
        guard actual.year == values[0], actual.month == values[1], actual.day == values[2] else {
            return nil
        }
        return result
    }

    private static func heading(_ value: String?) -> Double? {
        switch value?.uppercased() {
        case "N": 0
        case "NE": 45
        case "E": 90
        case "SE": 135
        case "S": 180
        case "SW": 225
        case "W": 270
        case "NW": 315
        default: nil
        }
    }
}
