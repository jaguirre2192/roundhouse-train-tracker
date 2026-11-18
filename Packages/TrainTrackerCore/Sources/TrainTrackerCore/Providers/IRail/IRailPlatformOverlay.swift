import Foundation

public actor IRailPlatformOverlay: PlatformRealtimeOverlay {
    public nonisolated let sourceName = "iRail"
    public nonisolated let supportedCountryCodes: Set<String> = ["BE"]

    private let client: any HTTPClient
    private let baseURL: URL
    private let userAgent: String
    private let now: @Sendable () -> Date

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://api.irail.be/v1")!,
        userAgent: String = "TrainTracker/0.1 (https://github.com/jaguirre2192)",
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.now = now
    }

    public func platformUpdates(for trip: TrainTrip) async throws -> [PlatformUpdate] {
        let candidates = trip.stopTimes
            .filter { !$0.isPassed && $0.station.countryCode.uppercased() == "BE" }
            .prefix(2)
        var updates: [PlatformUpdate] = []

        for stop in candidates {
            let board = try await liveboard(stationName: stop.station.displayName)
            guard let departure = bestMatch(for: stop, trip: trip, in: board.departures.departure),
                  let platform = normalized(departure.platform)
            else { continue }
            let observedAt = TimeInterval(board.timestamp).map(Date.init(timeIntervalSince1970:)) ?? now()
            updates.append(
                PlatformUpdate(
                    tripID: trip.id,
                    stopSequence: stop.sequence,
                    stationID: stop.station.id,
                    plannedPlatform: stop.plannedPlatform,
                    expectedPlatform: platform,
                    observedAt: observedAt,
                    source: sourceName
                )
            )
        }
        return updates
    }

    private func liveboard(stationName: String) async throws -> IRailBoardDTO {
        guard var components = URLComponents(
            url: baseURL.appending(path: "liveboard"),
            resolvingAgainstBaseURL: false
        ) else {
            throw RailAdapterError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "station", value: stationName),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "lang", value: "en"),
        ]
        guard let url = components.url else { throw RailAdapterError.invalidRequest }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await client.decoded(IRailBoardDTO.self, from: request)
    }

    private func bestMatch(
        for stop: StopTime,
        trip: TrainTrip,
        in departures: [IRailDepartureDTO]
    ) -> IRailDepartureDTO? {
        let tripNumbers = numericTokens(in: trip.product)
        let scheduled = stop.scheduledDeparture ?? stop.scheduledArrival
        return departures
            .filter { departure in
                let identifiers = [
                    departure.vehicle,
                    departure.vehicleinfo?.shortname,
                    departure.vehicleinfo?.number,
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                let numberMatches = !tripNumbers.isDisjoint(with: numericTokens(in: identifiers))
                guard numberMatches else { return false }
                guard let scheduled, let epoch = TimeInterval(departure.time) else { return true }
                return abs(Date(timeIntervalSince1970: epoch).timeIntervalSince(scheduled)) < 45 * 60
            }
            .min { lhs, rhs in
                matchDistance(lhs, scheduled: scheduled) < matchDistance(rhs, scheduled: scheduled)
            }
    }

    private func matchDistance(_ value: IRailDepartureDTO, scheduled: Date?) -> TimeInterval {
        guard let scheduled, let epoch = TimeInterval(value.time) else { return 0 }
        return abs(Date(timeIntervalSince1970: epoch).timeIntervalSince(scheduled))
    }

    private func numericTokens(in value: String) -> Set<String> {
        Set(value.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count >= 2 })
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value != "?"
        else { return nil }
        return value
    }
}

private struct IRailBoardDTO: Decodable, Sendable {
    let timestamp: String
    let departures: IRailDeparturesDTO
}

private struct IRailDeparturesDTO: Decodable, Sendable {
    let departure: [IRailDepartureDTO]
}

private struct IRailDepartureDTO: Decodable, Sendable {
    let time: String
    let vehicle: String?
    let vehicleinfo: IRailVehicleDTO?
    let platform: String?
}

private struct IRailVehicleDTO: Decodable, Sendable {
    let shortname: String?
    let number: String?
}
