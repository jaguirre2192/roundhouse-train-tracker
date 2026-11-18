import Foundation
import TrainTrackerCore

@MainActor
struct JourneyPlanPreviewData {
    let trips: [TrainTrip]
    let plans: [TrackedJourneyPlan]
    let showsPushWarning: Bool
    let referenceDate: Date?

    static func resolve(arguments: [String], now: Date = .now) -> Self? {
        #if !DEBUG
        return nil
        #else
        if arguments.contains("-PublishedConnectionQA") { return PublishedConnectionPreview.seed }
        if arguments.contains("-StationClocksQA") { return StationClockPreview.seed }
        if arguments.contains("-ConnectionRecoveryQA") { return JourneyRecoveryPreview.seed }
        if arguments.contains("-MyTripsTicketHistoryPreview") || arguments.contains("-MyTripsPastPlansQA") {
            return ticketHistoryPreview()
        }
        if arguments.contains("-MyTripsTimeBucketsQA") || arguments.contains("-MyTripsPastOnlyQA") {
            return timeBucketsQA(arguments: arguments)
        }
        guard arguments.contains("-JourneyPlanPreview") else { return nil }

        let paris = station(id: "paris-nord", name: "Paris Nord", code: "PNO", latitude: 48.88, longitude: 2.35)
        let brussels = station(id: "bruxelles-midi", name: "Bruxelles-Midi", code: "BRU", latitude: 50.84, longitude: 4.34)
        let amsterdam = station(id: "amsterdam-centraal", name: "Amsterdam Centraal", code: "ASD", latitude: 52.38, longitude: 4.90)
        let london = station(id: "london-kings-cross", name: "London King's Cross", code: "KGX", latitude: 51.53, longitude: -0.12)
        let edinburgh = station(id: "edinburgh-waverley", name: "Edinburgh Waverley", code: "EDB", latitude: 55.95, longitude: -3.19)

        let active = trip(
            id: "eurostar-9321",
            serviceDate: now,
            product: "Eurostar 9321",
            headsign: "Bruxelles-Midi",
            stations: [paris, brussels],
            departure: now.addingTimeInterval(-30 * 60),
            duration: 92 * 60,
            isActive: true,
            routeGeometry: RouteGeometry(
                source: "Preview rail shape",
                segments: [RouteGeometry.Segment(
                    encodedPolyline: "_{iiHo~iM_jZonT_g^_xq@_af@_ieAosw@_skC_af@oh\\_uu@okX_ry@_mVodkA_jZ",
                    precision: 5,
                    pointCount: 9
                )]
            )
        )
        let connection = trip(
            id: "eurostar-9369",
            serviceDate: now,
            product: "Eurostar 9369",
            headsign: "Amsterdam Centraal",
            stations: [brussels, amsterdam],
            departure: now.addingTimeInterval(105 * 60),
            duration: 118 * 60
        )
        let returnTrip = trip(
            id: "eurostar-9340",
            serviceDate: now.addingTimeInterval(24 * 60 * 60),
            product: "Eurostar 9340",
            headsign: "Paris Nord",
            stations: [amsterdam, paris],
            departure: now.addingTimeInterval(27 * 60 * 60),
            duration: 210 * 60
        )
        let legacy = trip(
            id: "lner-225",
            serviceDate: now.addingTimeInterval(2 * 24 * 60 * 60),
            product: "LNER 225",
            headsign: "Edinburgh Waverley",
            stations: [london, edinburgh],
            departure: now.addingTimeInterval(52 * 60 * 60),
            duration: 270 * 60
        )
        let parisPlace = place(
            id: "paris", name: "Paris", countryCode: "FR",
            timeZoneIdentifier: "Europe/Paris", station: paris
        )
        let brusselsPlace = place(
            id: "brussels", name: "Brussels", countryCode: "BE",
            timeZoneIdentifier: "Europe/Brussels", station: brussels
        )
        let amsterdamPlace = place(
            id: "amsterdam", name: "Amsterdam", countryCode: "NL",
            timeZoneIdentifier: "Europe/Amsterdam", station: amsterdam
        )
        let missingID = RailIdentifier(rawValue: "eu:transitous:missing-connection")

        let roundTrip = TrackedJourneyPlan(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: now,
            origin: parisPlace,
            destination: amsterdamPlace,
            outbound: JourneyPlanDirection(
                fingerprint: "preview-round-outbound",
                departure: departure(of: active),
                arrival: arrival(of: connection),
                childTripIDs: [active.id, connection.id]
            ),
            returnDirection: JourneyPlanDirection(
                fingerprint: "preview-round-return",
                departure: departure(of: returnTrip),
                arrival: arrival(of: returnTrip),
                childTripIDs: [returnTrip.id]
            ),
            preExistingChildTripIDs: [active.id]
        )
        let oneWay = TrackedJourneyPlan(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            createdAt: now,
            origin: brusselsPlace,
            destination: amsterdamPlace,
            outbound: JourneyPlanDirection(
                fingerprint: "preview-one-way",
                departure: departure(of: connection),
                arrival: arrival(of: connection),
                childTripIDs: [connection.id, missingID]
            ),
            returnDirection: nil,
            preExistingChildTripIDs: []
        )

        return Self(
            trips: [active, connection, returnTrip, legacy],
            plans: [roundTrip, oneWay],
            showsPushWarning: arguments.contains("-JourneyPlanPreviewPushWarning"),
            referenceDate: nil
        )
        #endif
    }

    #if DEBUG
    /// Deterministic history fixtures for the actual root, including city scope and long names.
    private static func ticketHistoryPreview() -> Self {
        let now = ISO8601DateFormatter().date(from: "2026-10-08T16:00:00Z")!
        func endpoint(_ id: String, _ name: String, country: String, latitude: Double, longitude: Double) -> Station {
            Station(id: RailIdentifier(rawValue: "preview:history:\(id)"),
                    names: [LocalizedStationName(name, localeIdentifier: "en")],
                    location: GeoCoordinate(latitude: latitude, longitude: longitude), countryCode: country)
        }
        let newYork = endpoint("new-york", "New York", country: "US", latitude: 40.75, longitude: -73.99)
        let washington = endpoint("washington", "Washington DC", country: "US", latitude: 38.90, longitude: -77.00)
        let valencia = endpoint("valencia", "València-Joaquín Sorolla", country: "ES", latitude: 39.46, longitude: -0.38)
        let madrid = endpoint("madrid", "Madrid-Puerta de Atocha-Almudena Grandes", country: "ES", latitude: 40.41, longitude: -3.69)
        func selectedPlace(_ station: Station, name: String? = nil, kind: RailPlace.Kind, zone: String) -> RailPlace {
            RailPlace(id: station.id, kind: kind, displayName: name ?? station.displayName,
                      context: kind == .city ? "All stations" : "Station", countryCode: station.countryCode,
                      timeZoneIdentifier: zone, location: station.location, eligibleModes: ["rail"],
                      attributions: ["Illustrative preview timetable"])
        }
        let routes: [(from: Station, to: Station, boarding: RailPlace, alighting: RailPlace,
                      utcDeparture: String, operatorName: String, service: String)] = [
            (newYork, washington,
             selectedPlace(newYork, name: "New York — All stations", kind: .city, zone: "America/New_York"),
             selectedPlace(washington, name: "Washington DC — All stations", kind: .city, zone: "America/New_York"),
             "2026-10-02T10:10:00Z", "Amtrak", "Northeast Regional 171"),
            (washington, newYork,
             selectedPlace(washington, kind: .city, zone: "America/New_York"),
             selectedPlace(newYork, kind: .city, zone: "America/New_York"), "2026-09-15T21:05:00Z", "Amtrak", "Northeast Regional 178"),
            (valencia, madrid,
             selectedPlace(valencia, kind: .station, zone: "Europe/Madrid"),
             selectedPlace(madrid, kind: .station, zone: "Europe/Madrid"), "2026-08-22T13:09:00Z", "Renfe", "AVE")
        ]
        var trips: [TrainTrip] = []
        var plans: [TrackedJourneyPlan] = []
        for (index, route) in routes.enumerated() {
            let departure = ISO8601DateFormatter().date(from: route.utcDeparture)!
            let train = trip(id: "history-\(index)", serviceDate: departure, product: route.service, operatorName: route.operatorName,
                             headsign: route.to.displayName, stations: [route.from, route.to],
                             departure: departure, duration: 10_800)
            trips.append(train)
            plans.append(TrackedJourneyPlan(id: UUID(uuidString: "77777777-7777-7777-7777-00000000000\(index)")!,
                createdAt: departure, origin: route.boarding, destination: route.alighting,
                outbound: JourneyPlanDirection(fingerprint: "history-\(index)", departure: departure,
                                              arrival: arrival(of: train), childTripIDs: [train.id]),
                returnDirection: nil, preExistingChildTripIDs: []))
        }
        let paris = endpoint("paris-nord", "Paris Nord", country: "FR", latitude: 48.88, longitude: 2.35)
        let brussels = endpoint("bruxelles-midi", "Bruxelles-Midi", country: "BE", latitude: 50.84, longitude: 4.34)
        let amsterdam = endpoint("amsterdam", "Amsterdam Centraal", country: "NL", latitude: 52.379, longitude: 4.900)
        let parisPlace = selectedPlace(paris, kind: .station, zone: "Europe/Paris")
        let brusselsPlace = selectedPlace(brussels, kind: .station, zone: "Europe/Brussels")
        let amsterdamPlace = selectedPlace(amsterdam, kind: .station, zone: "Europe/Amsterdam")
        let departure = ISO8601DateFormatter().date(from: "2026-10-07T07:24:00Z")!
        let first = trip(id: "history-paris-brussels", serviceDate: departure, product: "Eurostar 9321",
                         headsign: brussels.displayName, stations: [paris, brussels], departure: departure, duration: 5_040)
        let second = trip(id: "history-brussels-amsterdam", serviceDate: departure, product: "Eurostar 9369",
                          headsign: amsterdam.displayName, stations: [brussels, amsterdam],
                          departure: departure.addingTimeInterval(6_900), duration: 7_020)
        trips += [first, second]
        plans.append(TrackedJourneyPlan(
            id: UUID(uuidString: "77777777-7777-7777-7777-000000000003")!, createdAt: departure,
            origin: parisPlace, destination: amsterdamPlace,
            outbound: JourneyPlanDirection(
                fingerprint: "history-photo-transfer", departure: departure, arrival: arrival(of: second),
                childTripIDs: [first.id, second.id], selectedSegments: [
                    JourneyPlanSegment(id: "history-leg-1", kind: .rail, from: parisPlace, to: brusselsPlace,
                                       departure: departure, arrival: arrival(of: first),
                                       serviceName: first.product, resolvedTripID: first.id),
                    JourneyPlanSegment(id: "history-leg-2", kind: .rail, from: brusselsPlace, to: amsterdamPlace,
                                       departure: Self.departure(of: second), arrival: arrival(of: second),
                                       serviceName: second.product, resolvedTripID: second.id)
                ]), returnDirection: nil, preExistingChildTripIDs: []))
        return Self(trips: trips, plans: plans, showsPushWarning: false, referenceDate: now)
    }

    /// Fixed timetable and save order exercise the actual My Trips phone and split-view roots.
    private static func timeBucketsQA(arguments: [String]) -> Self {
        let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
        let paris = station(id: "paris-nord", name: "Paris Nord", code: "PNO", latitude: 48.88, longitude: 2.35)
        let brussels = station(id: "bruxelles-midi", name: "Bruxelles-Midi", code: "BRU", latitude: 50.84, longitude: 4.34)
        func train(_ number: Int, departure: TimeInterval, duration: TimeInterval = 7_200) -> TrainTrip {
            trip(id: "time-bucket-\(number)", serviceDate: now,
                 product: "Eurostar \(number)", headsign: "Bruxelles-Midi",
                 stations: [paris, brussels], departure: now.addingTimeInterval(departure), duration: duration)
        }
        let later = train(9502, departure: 7_200)
        let nearest = train(9501, departure: 1_800)
        if arguments.contains("-MyTripsUpcomingOnlyQA") {
            return Self(trips: [later, nearest], plans: [], showsPushWarning: false, referenceDate: now)
        }
        let active = train(9401, departure: -1_800)
        let otherCurrent = train(9402, departure: -3_600)
        let older = train(9301, departure: -172_800)
        let recent = train(9302, departure: -86_400)
        if arguments.contains("-MyTripsPastOnlyQA") {
            return Self(trips: [older, recent], plans: [], showsPushWarning: false, referenceDate: now)
        }
        let untimed = TrainTrip(
            id: RailIdentifier(rawValue: "eu:preview:untimed"), source: "preview",
            serviceDate: now.addingTimeInterval(-86_400), operatorName: "Eurostar",
            product: "Eurostar 9601", headsign: "Bruxelles-Midi",
            stopTimes: [StopTime(station: paris, sequence: 0), StopTime(station: brussels, sequence: 1)],
            capabilities: active.capabilities
        )
        return Self(trips: [later, nearest, active, otherCurrent, older, recent, untimed],
                    plans: [], showsPushWarning: false, referenceDate: now)
    }
    #endif

    private static func station(
        id: String,
        name: String,
        code: String,
        latitude: Double,
        longitude: Double
    ) -> Station {
        Station(
            id: RailIdentifier(rawValue: "eu:preview:\(id)"),
            names: [LocalizedStationName(name, localeIdentifier: "en")],
            codes: [.sourceNative: code],
            location: GeoCoordinate(latitude: latitude, longitude: longitude),
            countryCode: "EU"
        )
    }

    private static func place(
        id: String,
        name: String,
        countryCode: String,
        timeZoneIdentifier: String,
        station: Station
    ) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: "eu:preview:\(id)"),
            kind: .city,
            displayName: name,
            context: "All mainline stations",
            countryCode: countryCode,
            timeZoneIdentifier: timeZoneIdentifier,
            location: station.location,
            eligibleModes: ["highSpeedRail"],
            attributions: ["Preview timetable"]
        )
    }

    private static func trip(
        id: String,
        serviceDate: Date,
        product: String,
        operatorName: String? = nil,
        headsign: String,
        stations: [Station],
        departure: Date,
        duration: TimeInterval,
        isActive: Bool = false,
        routeGeometry: RouteGeometry? = nil
    ) -> TrainTrip {
        let finalArrival = departure.addingTimeInterval(duration)
        let stops = stations.enumerated().map { index, station in
            let isOrigin = index == 0
            let date = isOrigin ? departure : finalArrival
            return StopTime(
                station: station,
                sequence: index + 1,
                scheduledArrival: isOrigin ? nil : date,
                scheduledDeparture: isOrigin ? date : nil,
                expectedArrival: isOrigin ? nil : date.addingTimeInterval(isActive ? 7 * 60 : 0),
                expectedDeparture: isOrigin ? date.addingTimeInterval(isActive ? 7 * 60 : 0) : nil,
                plannedPlatform: isOrigin ? "8" : "4",
                expectedPlatform: isOrigin ? "9" : "4",
                isPassed: isActive && isOrigin
            )
        }
        let position = VehiclePosition(
            coordinate: GeoCoordinate(latitude: 49.67, longitude: 3.80),
            heading: 25,
            source: .real,
            confidence: 0.96,
            asOf: serviceDate
        )
        return TrainTrip(
            id: RailIdentifier(rawValue: "eu:preview:\(id)"),
            source: "preview",
            serviceDate: serviceDate,
            operatorName: operatorName ?? (product.hasPrefix("LNER") ? "LNER" : "Eurostar"),
            product: product,
            headsign: headsign,
            stopTimes: stops,
            routeGeometry: routeGeometry,
            positions: isActive ? [position] : [],
            capabilities: RealtimeCapabilities(
                hasPositions: isActive,
                hasPlatforms: true,
                hasRealtimeDelays: true,
                hasAlerts: true,
                granularity: .perStop
            )
        )
    }

    private static func departure(of trip: TrainTrip) -> Date {
        trip.stopTimes.first?.scheduledDeparture ?? trip.serviceDate
    }

    private static func arrival(of trip: TrainTrip) -> Date {
        trip.stopTimes.last?.scheduledArrival ?? trip.serviceDate
    }
}

@MainActor
final class JourneyPlanPreviewArchive: JourneyPlanArchiving {
    private var plans: [TrackedJourneyPlan]

    init(plans: [TrackedJourneyPlan]) {
        self.plans = plans
    }

    func load() throws -> [TrackedJourneyPlan] { plans }
    func save(_ plans: [TrackedJourneyPlan]) throws { self.plans = plans }
    func loadTrackingAttempts() throws -> [JourneyPlanTrackingAttempt] { [] }
    func saveTrackingAttempts(_ attempts: [JourneyPlanTrackingAttempt]) throws {}
}

@MainActor
final class JourneyPlanPreviewPushCoordinator: PushCoordinating {
    var deliveryWarningHandler: ((PushDeliveryWarningEvent) -> Void)?

    func connect() {}
    func watch(_ trip: TrainTrip) {}
    func unwatch(_ trip: TrainTrip) {}

    func showWarning(for tripIDs: Set<RailIdentifier>) {
        deliveryWarningHandler?(PushDeliveryWarningEvent(
            reason: .backendSynchronizationFailed,
            affectedTripIDs: tripIDs
        ))
    }
}
