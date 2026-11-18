import Foundation
import TrainTrackerCore

actor TripSnapshotBackendClient {
    enum ClientError: Error, LocalizedError {
        case notConfigured
        case invalidRequest
        case invalidResponse
        case rejected(Int)
        /// The service asked for a pause. Keep saved data and try again after the pause.
        case rateLimited(retryAfter: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .rateLimited: "Roundhouse is busy right now. Try again shortly."
            case .notConfigured, .invalidRequest, .invalidResponse, .rejected: nil
            }
        }
    }

    private struct StationSnapshot: Decodable {
        let id: String
        let nativeId: String
        let name: String
        let countryCode: String
        let latitude: Double
        let longitude: Double
        let operatorHints: [String]
    }

    private struct BoardEntrySnapshot: Decodable {
        struct TripReference: Decodable {
            let id: String
            let serviceDate: String
        }

        let trip: TripReference
        let stop: BackendTripSnapshot.Stop
        let headsign: String
        let product: String
    }

    nonisolated let isConfigured: Bool

    private let baseURL: URL?
    private let client: any HTTPClient
    private let now: @Sendable () -> Date
    /// While the service's Retry-After is pending, requests fail locally instead of looping.
    private var rateLimitedUntil: Date?

    init(
        baseURL: URL? = TrainTrackerBackendConfiguration.baseURL,
        client: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.baseURL = baseURL
        self.client = client
        self.now = now
        isConfigured = baseURL != nil
    }

    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip {
        let reference = try BackendRailReference(id: trip.id, sourceHint: trip.source)
        guard reference.source == trip.source else { throw ClientError.invalidRequest }
        let snapshot: BackendTripSnapshot = try await get(path: "v1/trips/snapshot", query: [
            URLQueryItem(name: "id", value: reference.id),
            URLQueryItem(name: "source", value: reference.source),
            URLQueryItem(name: "nativeId", value: reference.nativeID),
            URLQueryItem(name: "serviceDate", value: Self.serviceDate(trip.serviceDate)),
        ])
        guard snapshot.hasValidWireDates, !snapshot.stops.isEmpty else { throw ClientError.invalidResponse }
        return snapshot.merging(into: trip)
    }

    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource? = nil) async throws -> TrainTrip {
        let reference = try BackendRailReference(id: id, sourceHint: BackendRailReference.provider(for: source))
        let snapshot: BackendTripSnapshot = try await get(path: "v1/trips/snapshot", query: [
            URLQueryItem(name: "id", value: reference.id),
            URLQueryItem(name: "source", value: reference.source),
            URLQueryItem(name: "nativeId", value: reference.nativeID),
            URLQueryItem(name: "serviceDate", value: Self.serviceDate(serviceDate)),
        ])
        guard snapshot.hasValidWireDates, !snapshot.stops.isEmpty else { throw ClientError.invalidResponse }
        return snapshot.trip
    }

    func searchStations(query: String, source: RailSource) async throws -> [Station] {
        let values: [StationSnapshot] = try await get(path: "v1/stations/search", query: [
            URLQueryItem(name: "scope", value: source == .unitedStates ? "us" : "international"),
            URLQueryItem(name: "query", value: query),
        ])
        return values.map(Self.station)
    }

    func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection,
        source: RailSource? = nil
    ) async throws -> [StopTimeSummary] {
        let reference = try BackendRailReference(id: stationID, sourceHint: BackendRailReference.provider(for: source))
        let values: [BoardEntrySnapshot] = try await get(path: "v1/stations/board", query: [
            URLQueryItem(name: "stationId", value: reference.id),
            URLQueryItem(name: "source", value: reference.source),
            URLQueryItem(name: "nativeId", value: reference.nativeID),
            URLQueryItem(name: "at", value: ISO8601DateFormatter().string(from: date)),
            URLQueryItem(name: "direction", value: direction.rawValue),
        ])
        return try values.map { value in
            guard let serviceDate = WireDate.date(from: value.trip.serviceDate) else {
                throw ClientError.invalidResponse
            }
            return StopTimeSummary(
                tripID: RailIdentifier(rawValue: value.trip.id),
                serviceDate: serviceDate,
                stopTime: BackendTripSnapshot.stop(value.stop, tripSource: RailIdentifier(rawValue: value.trip.id).source ?? ""),
                headsign: value.headsign,
                product: value.product
            )
        }
    }

    private static func station(_ value: StationSnapshot) -> Station {
        Station(
            id: RailIdentifier(rawValue: value.id),
            names: [LocalizedStationName(value.name)],
            codes: [.sourceNative: value.nativeId],
            location: GeoCoordinate(latitude: value.latitude, longitude: value.longitude),
            countryCode: value.countryCode,
            operatorHints: value.operatorHints
        )
    }

    private func get<Response: Decodable>(path: String, query: [URLQueryItem]) async throws -> Response {
        guard let baseURL else { throw ClientError.notConfigured }
        if let rateLimitedUntil, rateLimitedUntil > now() {
            throw ClientError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSince(now()))
        }
        guard var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else { throw ClientError.invalidRequest }
        components.queryItems = query
        guard let url = components.url else { throw ClientError.invalidRequest }
        var request = URLRequest(url: url, timeoutInterval: RailRequestBudget.timeoutInterval)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await client.send(request)
        if response.statusCode == 429 {
            let delay = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now())
            rateLimitedUntil = now().addingTimeInterval(delay)
            throw ClientError.rateLimited(retryAfter: delay)
        }
        guard response.statusCode == 200 else { throw ClientError.rejected(response.statusCode) }
        return try JSONDecoder().decode(Response.self, from: response.data)
    }

    /// Retry-After may be seconds or an HTTP date; keep the pause between 1 second and 1 hour.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval {
        let value = value?.trimmingCharacters(in: .whitespaces) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let seconds = TimeInterval(value) ?? formatter.date(from: value)?.timeIntervalSince(now) ?? 60
        return seconds.isFinite ? min(max(seconds, 1), 3_600) : 60
    }

    private static func serviceDate(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

}
