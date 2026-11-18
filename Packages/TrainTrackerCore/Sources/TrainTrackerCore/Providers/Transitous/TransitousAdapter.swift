import Foundation

public actor TransitousAdapter: RailAdapter, AlertProviding, ProviderHealthChecking, JourneyPlanning {
    public nonisolated let capabilities = TransitousMapper.capabilities

    private let client: any HTTPClient
    private let baseURL: URL
    private let userAgent: String
    private let now: @Sendable () -> Date
    private var stationCache: [RailIdentifier: Station] = [:]

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://api.transitous.org")!,
        userAgent: String? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.baseURL = baseURL
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        self.userAgent = userAgent ?? "Roundhouse/\(version) (+https://gettraintracker.com/support)"
        self.now = now
    }

    public func searchStations(query: String) async throws -> [Station] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        var seen = Set<RailIdentifier>()
        var stations: [Station] = []
        for searchValue in TransitousSearchQueries.values(for: query) {
            let values: TransitousGeocodeResponse = try await decode(
                path: "/api/v1/geocode",
                query: [
                    URLQueryItem(name: "text", value: searchValue),
                    URLQueryItem(name: "type", value: "STOP"),
                    URLQueryItem(name: "mode", value: TransitousRailModes.parameter),
                    URLQueryItem(name: "language", value: "en"),
                    URLQueryItem(name: "numResults", value: "20"),
                ]
            )
            let matchingStations = values
                .filter {
                    $0.type == "STOP"
                        && TransitousMainlineScope.acceptsStation(nativeID: $0.id, countryCode: $0.country)
                }
                .map(TransitousMapper.station)
            for station in matchingStations where seen.insert(station.id).inserted {
                stations.append(station)
            }
        }
        stations = Array(stations.prefix(20))
        for station in stations {
            stationCache[station.id] = station
        }
        return stations
    }

    public func resolveStation(id: RailIdentifier) async throws -> Station {
        if let cached = stationCache[id] { return cached }
        let nativeID = try nativeID(from: id)
        let response = try await stopTimes(stationNativeID: nativeID, at: now(), direction: .departures, count: 1)
        let station = TransitousMapper.station(response.place)
        stationCache[id] = station
        return station
    }

    public func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection
    ) async throws -> [StopTimeSummary] {
        let nativeID = try nativeID(from: stationID)
        let response = try await stopTimes(stationNativeID: nativeID, at: date, direction: direction, count: 30)
        return response.stopTimes
            .filter {
                TransitousRailModes.isMainline($0.mode)
                    && TransitousMainlineScope.acceptsDeparture(
                        tripID: $0.tripId,
                        routeLongName: $0.routeLongName
                    )
            }
            .map { TransitousMapper.summary($0, serviceDate: date, now: now()) }
            .sorted { boardDate($0.stopTime, direction: direction) < boardDate($1.stopTime, direction: direction) }
    }

    public func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        let nativeID = try nativeID(from: id)
        let itinerary: TransitousItineraryDTO = try await decode(
            path: "/api/v6/trip",
            query: [
                URLQueryItem(name: "tripId", value: nativeID),
                URLQueryItem(name: "detailedLegs", value: "true"),
                URLQueryItem(name: "joinInterlinedLegs", value: "false"),
                URLQueryItem(name: "language", value: "en"),
            ]
        )
        return try TransitousMapper.trip(
            itinerary,
            nativeTripID: nativeID,
            serviceDate: serviceDate,
            now: now()
        )
    }

    public func alerts(affecting tripID: RailIdentifier) async throws -> [RailAlert] {
        try await trip(id: tripID, serviceDate: now()).alerts
    }

    public func planJourney(
        from originID: RailIdentifier,
        to destinationID: RailIdentifier,
        at date: Date,
        arriveBy: Bool
    ) async throws -> [Journey] {
        let origin = try nativeID(from: originID)
        let destination = try nativeID(from: destinationID)
        let response: TransitousPlanDTO = try await decode(
            path: "/api/v6/plan",
            query: [
                URLQueryItem(name: "fromPlace", value: origin),
                URLQueryItem(name: "toPlace", value: destination),
                URLQueryItem(name: "time", value: RailDateParser.string(from: date)),
                URLQueryItem(name: "arriveBy", value: arriveBy.description),
                URLQueryItem(name: "maxTransfers", value: "4"),
                URLQueryItem(name: "transitModes", value: TransitousRailModes.parameter),
                URLQueryItem(name: "directModes", value: ""),
                URLQueryItem(name: "detailedLegs", value: "false"),
                URLQueryItem(name: "detailedTransfers", value: "false"),
                URLQueryItem(name: "joinInterlinedLegs", value: "false"),
                URLQueryItem(name: "language", value: "en"),
            ]
        )
        return response.itineraries.enumerated().map { TransitousMapper.journey($0.element, index: $0.offset) }
    }

    public func health() async throws -> ProviderHealth {
        let value: TransitousHealthDTO = try await decode(path: "/api/v1/health")
        return ProviderHealth(
            status: value.rt ? .healthy : .degraded,
            checkedAt: now(),
            message: value.rt ? nil : "Transitous realtime ingestion is unavailable; schedules may still work."
        )
    }

    private func stopTimes(
        stationNativeID: String,
        at date: Date,
        direction: BoardDirection,
        count: Int
    ) async throws -> TransitousStopTimesDTO {
        try await decode(
            path: "/api/v6/stoptimes",
            query: [
                URLQueryItem(name: "stopId", value: stationNativeID),
                URLQueryItem(name: "time", value: RailDateParser.string(from: date)),
                URLQueryItem(name: "arriveBy", value: (direction == .arrivals).description),
                URLQueryItem(name: "mode", value: TransitousRailModes.parameter),
                URLQueryItem(name: "n", value: count.description),
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "withAlerts", value: "true"),
            ]
        )
    }

    private func decode<Response: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        guard var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw RailAdapterError.invalidRequest
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw RailAdapterError.invalidRequest }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await client.decoded(Response.self, from: request)
    }

    private func nativeID(from id: RailIdentifier) throws -> String {
        if id.isNamespaced {
            guard id.region == "eu", id.source == "transitous", let nativeID = id.nativeID else {
                throw RailAdapterError.invalidIdentifier(id.rawValue)
            }
            return nativeID
        }
        guard !id.rawValue.isEmpty else { throw RailAdapterError.invalidIdentifier(id.rawValue) }
        return id.rawValue
    }

    private func boardDate(_ stop: StopTime, direction: BoardDirection) -> Date {
        switch direction {
        case .arrivals:
            stop.expectedArrival ?? stop.scheduledArrival ?? .distantFuture
        case .departures:
            stop.expectedDeparture ?? stop.scheduledDeparture ?? .distantFuture
        }
    }
}
