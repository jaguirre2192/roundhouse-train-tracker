import Foundation

public actor AmtrakerAdapter: RailAdapter, VehiclePositionProviding, AlertProviding, ProviderHealthChecking {
    public nonisolated let capabilities = AmtrakerMapper.capabilities

    private let client: any HTTPClient
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private var cachedStations: (loadedAt: Date, values: [String: AmtrakerStationDTO])?
    private var cachedTrains: (loadedAt: Date, values: [AmtrakerTrainDTO])?

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://api.amtraker.com/v3")!,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.now = now
    }

    public func searchStations(query: String) async throws -> [Station] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let stations = try await stationCatalog().values.filter { value in
            value.code.localizedCaseInsensitiveContains(query)
                || value.name.localizedCaseInsensitiveContains(query)
                || value.city?.localizedCaseInsensitiveContains(query) == true
                || value.state?.localizedCaseInsensitiveContains(query) == true
        }
        return stations
            .sorted { stationScore($0, query: query) < stationScore($1, query: query) }
            .prefix(20)
            .map(AmtrakerMapper.station)
    }

    public func resolveStation(id: RailIdentifier) async throws -> Station {
        let code = try nativeID(from: id)
        let response: AmtrakerStationResponse = try await decode(path: "stations/\(encoded(code))")
        guard let station = response[code] ?? response.values.first else {
            throw RailAdapterError.notFound
        }
        return AmtrakerMapper.station(station)
    }

    public func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection
    ) async throws -> [StopTimeSummary] {
        let code = try nativeID(from: stationID)
        let stationValues = try await stationCatalog()
        let trains = try await allTrains()
        let window = date.addingTimeInterval(-12 * 60 * 60) ... date.addingTimeInterval(24 * 60 * 60)

        return trains.compactMap { train -> StopTimeSummary? in
            guard let stopIndex = train.stations.firstIndex(where: { $0.code == code }) else { return nil }
            let trip = AmtrakerMapper.trip(
                train,
                serviceDate: AmtrakerMapper.boardServiceDate(
                    train.stations[stopIndex],
                    direction: direction,
                    fallback: date
                ),
                stations: stationValues,
                now: now()
            )
            let stopTime = trip.stopTimes[stopIndex]
            let relevantDate = direction == .arrivals
                ? stopTime.expectedArrival ?? stopTime.scheduledArrival
                : stopTime.expectedDeparture ?? stopTime.scheduledDeparture
            guard let relevantDate, window.contains(relevantDate) else { return nil }
            return StopTimeSummary(
                tripID: trip.id,
                serviceDate: trip.serviceDate,
                stopTime: stopTime,
                headsign: trip.headsign,
                product: trip.product
            )
        }
        .sorted { lhs, rhs in
            boardDate(lhs.stopTime, direction: direction) < boardDate(rhs.stopTime, direction: direction)
        }
    }

    public func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip {
        let nativeID = try nativeID(from: id)
        let response: AmtrakerTrainResponse = try await decode(path: "trains/\(encoded(nativeID))")
        let candidates = response.values.flatMap { $0 }
        guard let train = candidates.first(where: { $0.trainID == nativeID })
            ?? candidates.first(where: { $0.trainNum == nativeID })
            ?? candidates.first
        else {
            throw RailAdapterError.notFound
        }
        let stations = try await stationCatalog()
        return AmtrakerMapper.trip(train, serviceDate: serviceDate, stations: stations, now: now())
    }

    /// Every live instance Amtraker reports for a train number (for example 2120-14 and 2120-15).
    func trainInstances(number: String) async throws -> [AmtrakerTrainDTO] {
        let response: AmtrakerTrainResponse = try await decode(path: "trains/\(encoded(number))")
        return response.values.flatMap { $0 }
    }

    func currentDate() -> Date { now() }

    public func positions(for tripID: RailIdentifier) async throws -> [VehiclePosition] {
        try await trip(id: tripID, serviceDate: now()).positions
    }

    public func alerts(affecting tripID: RailIdentifier) async throws -> [RailAlert] {
        try await trip(id: tripID, serviceDate: now()).alerts
    }

    public func health() async throws -> ProviderHealth {
        let value: AmtrakerStaleDTO = try await decode(path: "stale")
        return ProviderHealth(
            status: value.stale ? .degraded : .healthy,
            checkedAt: now(),
            averageDataAge: value.avgLastUpdate.map { $0 / 1_000 },
            activeServices: value.activeTrains,
            message: value.stale ? "Amtraker marked its upstream data stale." : nil
        )
    }

    private func stationCatalog() async throws -> [String: AmtrakerStationDTO] {
        if let cachedStations, now().timeIntervalSince(cachedStations.loadedAt) < 6 * 60 * 60 {
            return cachedStations.values
        }
        let values: AmtrakerStationResponse = try await decode(path: "stations")
        cachedStations = (now(), values)
        return values
    }

    private func allTrains() async throws -> [AmtrakerTrainDTO] {
        if let cachedTrains, now().timeIntervalSince(cachedTrains.loadedAt) < 30 {
            return cachedTrains.values
        }
        let response: AmtrakerTrainResponse = try await decode(path: "trains")
        let values = response.values.flatMap { $0 }
        cachedTrains = (now(), values)
        return values
    }

    private func decode<Response: Decodable & Sendable>(path: String) async throws -> Response {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TrainTracker/0.1", forHTTPHeaderField: "User-Agent")
        return try await client.decoded(Response.self, from: request)
    }

    private func nativeID(from id: RailIdentifier) throws -> String {
        if id.isNamespaced {
            guard id.region == "us", id.source == "amtraker", let nativeID = id.nativeID else {
                throw RailAdapterError.invalidIdentifier(id.rawValue)
            }
            return nativeID
        }
        guard !id.rawValue.isEmpty else { throw RailAdapterError.invalidIdentifier(id.rawValue) }
        return id.rawValue
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func stationScore(_ station: AmtrakerStationDTO, query: String) -> Int {
        if station.code.localizedCaseInsensitiveCompare(query) == .orderedSame { return 0 }
        if station.name.lowercased().hasPrefix(query.lowercased()) { return 1 }
        if station.city?.lowercased().hasPrefix(query.lowercased()) == true { return 2 }
        return 3
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
