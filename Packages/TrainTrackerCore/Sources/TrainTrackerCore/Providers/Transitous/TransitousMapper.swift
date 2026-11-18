import Foundation

enum TransitousMapper {
    static let capabilities = RealtimeCapabilities(
        hasPositions: false,
        hasPlatforms: true,
        hasRealtimeDelays: true,
        hasAlerts: true,
        granularity: .perStop
    )

    static func station(_ value: TransitousGeocodeDTO) -> Station {
        Station(
            id: stationID(value.id),
            names: [LocalizedStationName(value.name)],
            codes: [.sourceNative: value.id],
            location: GeoCoordinate(latitude: value.lat, longitude: value.lon),
            countryCode: value.country?.uppercased() ?? countryCode(from: value.id),
            operatorHints: []
        )
    }

    static func station(_ value: TransitousPlaceDTO) -> Station {
        let nativeID = value.stopId ?? "\(value.lat),\(value.lon)"
        return Station(
            id: stationID(nativeID),
            names: [LocalizedStationName(value.name)],
            codes: [.sourceNative: nativeID, .gtfs: nativeID],
            location: GeoCoordinate(latitude: value.lat, longitude: value.lon),
            countryCode: countryCode(from: nativeID),
            operatorHints: []
        )
    }

    static func summary(
        _ value: TransitousStopTimeDTO,
        serviceDate: Date,
        now: Date
    ) -> StopTimeSummary {
        let stop = stopTime(value.place, sequence: 1, now: now)
        return StopTimeSummary(
            tripID: tripID(value.tripId),
            serviceDate: TransitousServiceDate.resolve(tripID: value.tripId, place: value.place, fallback: serviceDate),
            stopTime: stop,
            headsign: value.headsign ?? value.tripTo?.name ?? "",
            product: product(
                displayName: value.displayName,
                routeShortName: value.routeShortName,
                tripShortName: value.tripShortName,
                fallback: value.mode
            )
        )
    }

    static func trip(
        _ value: TransitousItineraryDTO,
        nativeTripID: String,
        serviceDate: Date,
        now: Date
    ) throws -> TrainTrip {
        let transitLegs = trackableLegs(value.legs.filter { $0.tripId != nil }, nativeTripID: nativeTripID)
        guard let firstLeg = transitLegs.first else { throw RailAdapterError.notFound }

        var places: [TransitousPlaceDTO] = []
        for leg in transitLegs {
            append(leg.from, to: &places)
            for stop in leg.intermediateStops ?? [] {
                append(stop, to: &places)
            }
            append(leg.to, to: &places)
        }

        let canonicalTripID = tripID(nativeTripID)
        let stopTimes = places.enumerated().map { index, place in
            stopTime(place, sequence: index + 1, now: now)
        }
        let allAlerts = places.flatMap { $0.alerts ?? [] }
        let routeSegments = transitLegs.compactMap { leg -> RouteGeometry.Segment? in
            guard let geometry = leg.legGeometry,
                  !geometry.points.isEmpty,
                  geometry.length > 1
            else { return nil }
            return RouteGeometry.Segment(
                encodedPolyline: geometry.points,
                precision: geometry.precision,
                pointCount: geometry.length
            )
        }

        return TrainTrip(
            id: canonicalTripID,
            source: "transitous",
            serviceDate: serviceDate,
            operatorName: firstLeg.agencyName ?? "European rail",
            product: product(
                displayName: firstLeg.displayName,
                routeShortName: firstLeg.routeShortName,
                tripShortName: firstLeg.tripShortName,
                fallback: firstLeg.mode
            ),
            headsign: firstLeg.headsign ?? stopTimes.last?.station.displayName ?? "",
            stopTimes: stopTimes,
            routeGeometry: routeSegments.isEmpty
                ? nil
                : RouteGeometry(source: "Transitous/MOTIS", segments: routeSegments),
            alerts: alerts(allAlerts, tripID: canonicalTripID),
            capabilities: capabilities
        )
    }

    static func journey(_ value: TransitousItineraryDTO, index: Int) -> Journey {
        let transitLegs = value.legs.filter { $0.tripId != nil }
        let legs = transitLegs.enumerated().compactMap { legIndex, leg -> JourneyLeg? in
            guard let nativeTripID = leg.tripId,
                  let fromID = leg.from.stopId,
                  let toID = leg.to.stopId
            else { return nil }
            return JourneyLeg(
                id: RailIdentifier(region: "eu", source: "transitous", nativeID: "journey-leg-\(index)-\(legIndex)"),
                tripID: tripID(nativeTripID),
                boardingStationID: stationID(fromID),
                alightingStationID: stationID(toID)
            )
        }

        let transfers = zip(transitLegs, transitLegs.dropFirst()).compactMap { previous, next -> JourneyTransfer? in
            guard let station = previous.to.stopId else { return nil }
            let arrival = RailDateParser.parse(previous.to.arrival) ?? RailDateParser.parse(previous.endTime)
            let departure = RailDateParser.parse(next.from.departure) ?? RailDateParser.parse(next.startTime)
            let minutes = max(Int((departure?.timeIntervalSince(arrival ?? departure ?? .now) ?? 0) / 60), 0)
            return JourneyTransfer(
                stationID: stationID(station),
                minimumConnectionMinutes: minutes,
                platformChange: platformChanged(from: previous.to, to: next.from)
            )
        }

        return Journey(
            id: RailIdentifier(
                region: "eu",
                source: "transitous",
                nativeID: value.id ?? "journey-\(index)-\(value.startTime)"
            ),
            legs: legs,
            transfers: transfers
        )
    }

    private static func stopTime(_ value: TransitousPlaceDTO, sequence: Int, now: Date) -> StopTime {
        let expectedDeparture = RailDateParser.parse(value.departure)
        let expectedArrival = RailDateParser.parse(value.arrival)
        return StopTime(
            station: station(value),
            sequence: sequence,
            scheduledArrival: RailDateParser.parse(value.scheduledArrival),
            scheduledDeparture: RailDateParser.parse(value.scheduledDeparture),
            expectedArrival: expectedArrival,
            expectedDeparture: expectedDeparture,
            plannedPlatform: normalized(value.scheduledTrack),
            expectedPlatform: normalized(value.track),
            isCancelled: value.cancelled == true,
            isPassed: (expectedDeparture ?? expectedArrival).map { $0 < now } == true
        )
    }

    private static func alerts(_ values: [TransitousAlertDTO], tripID: RailIdentifier) -> [RailAlert] {
        var seen = Set<String>()
        return values.enumerated().compactMap { index, value in
            let key = value.code ?? "\(value.headerText)|\(value.descriptionText)"
            guard seen.insert(key).inserted else { return nil }
            let message = [value.headerText, value.descriptionText]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            return RailAlert(
                id: RailIdentifier(
                    region: "eu",
                    source: "transitous",
                    nativeID: value.code ?? "alert-\(index)"
                ),
                severity: severity(value.severityLevel),
                cause: value.cause,
                affectedTripIDs: [tripID],
                message: message
            )
        }
    }

    private static func append(_ value: TransitousPlaceDTO, to places: inout [TransitousPlaceDTO]) {
        if let previous = places.last,
           previous.stopId == value.stopId,
           previous.scheduledArrival == value.scheduledArrival,
           previous.scheduledDeparture == value.scheduledDeparture {
            return
        }
        places.append(value)
    }

    private static func trackableLegs(
        _ transitLegs: [TransitousLegDTO],
        nativeTripID: String
    ) -> [TransitousLegDTO] {
        guard nativeTripID.contains("_jp-") else { return transitLegs }
        let exact = transitLegs.filter { $0.tripId == nativeTripID }
        return exact.isEmpty ? transitLegs : exact
    }

    private static func product(
        displayName: String?,
        routeShortName: String?,
        tripShortName: String?,
        fallback: String
    ) -> String {
        if let displayName = normalized(displayName) { return displayName }
        return [normalized(routeShortName), normalized(tripShortName)]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty ?? fallback.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func platformChanged(from: TransitousPlaceDTO, to: TransitousPlaceDTO) -> Bool? {
        guard let first = normalized(from.track), let second = normalized(to.track) else { return nil }
        return first != second
    }

    private static func severity(_ value: String?) -> AlertSeverity {
        switch value?.uppercased() {
        case "SEVERE": .critical
        case "WARNING": .major
        case "INFO": .information
        default: .minor
        }
    }

    private static func countryCode(from nativeID: String) -> String {
        let prefix = nativeID.prefix(2)
        guard prefix.count == 2, prefix.allSatisfy(\.isLetter) else { return "EU" }
        return prefix.uppercased()
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func stationID(_ nativeID: String) -> RailIdentifier {
        RailIdentifier(region: "eu", source: "transitous", nativeID: nativeID)
    }

    private static func tripID(_ nativeID: String) -> RailIdentifier {
        RailIdentifier(region: "eu", source: "transitous", nativeID: nativeID)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
