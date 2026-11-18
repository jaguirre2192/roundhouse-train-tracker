import Foundation
import TrainTrackerCore

protocol LiveActivityBackendServing: Sendable {
    func register(_ registration: LiveActivityRegistration) async throws
    func end(activityID: String, installationID: UUID) async throws
}

struct LiveActivityRegistration: Encodable, Sendable {
    struct TripReference: Encodable, Sendable {
        let id: String
        let source: String
        let nativeId: String
        let serviceDate: String
    }
    let schemaVersion = 1
    let installationId: String
    let activityId: String
    let token: String
    let environment: String
    let trip: TripReference
    let boardingStationId: String
    let alightingStationId: String
    let boardingStopSequence: Int
    let alightingStopSequence: Int
    let isRiding: Bool?
    let startedAt: String
    let initialContentState: TrainLiveActivityState
    let stationTimeZones: [String: String]
    let tokenGeneration: Int

    init(
        installationID: UUID, activityID: String, token: Data, environment: String,
        attributes: TrainJourneyAttributes, trip: TrainTrip, state: TrainLiveActivityState,
        stationTimeZones: [RailIdentifier: String], tokenGeneration: Int
    ) {
        installationId = installationID.uuidString.lowercased()
        activityId = activityID
        self.token = token.map { String(format: "%02x", $0) }.joined()
        self.environment = environment
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        self.trip = TripReference(
            id: trip.id.rawValue, source: trip.source,
            nativeId: trip.id.nativeID ?? trip.id.rawValue, serviceDate: formatter.string(from: trip.serviceDate)
        )
        boardingStationId = attributes.boardingStationID
        alightingStationId = attributes.alightingStationID
        boardingStopSequence = attributes.boardingStopSequence
        alightingStopSequence = attributes.alightingStopSequence
        isRiding = attributes.isRiding
        startedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: attributes.startedAt))
        initialContentState = state
        let selectedStops = trip.stopTimes.filter {
            $0.sequence >= attributes.boardingStopSequence && $0.sequence <= attributes.alightingStopSequence
        }
        let orderedIDs = [attributes.boardingStationID, attributes.alightingStationID]
            + selectedStops.map { $0.station.id.rawValue }
        var boundedZones: [String: String] = [:]
        for id in orderedIDs where boundedZones.count < 100 {
            if let zone = stationTimeZones[RailIdentifier(rawValue: id)], TimeZone(identifier: zone) != nil {
                boundedZones[id] = zone
            }
        }
        self.stationTimeZones = boundedZones
        self.tokenGeneration = tokenGeneration
    }
}

actor LiveActivityBackendClient: LiveActivityBackendServing {
    nonisolated static var pushEnvironment: String { TrainTrackerBackendConfiguration.apnsEnvironment }
    /// `unauthorized` means this installation's device credential no longer matches the server,
    /// as on a phone restored from backup; only a replacement installation can recover.
    enum ClientError: Error { case unavailable, unauthorized, rejected(Int) }
    private let baseURL: URL?
    private let client: any HTTPClient
    private let credential: @Sendable () throws -> String

    init(
        baseURL: URL? = TrainTrackerBackendConfiguration.baseURL,
        client: any HTTPClient = URLSessionHTTPClient(),
        credential: @escaping @Sendable () throws -> String = { try PushInstallationCredentialStore.loadOrCreate() }
    ) {
        self.baseURL = baseURL
        self.client = client
        self.credential = credential
    }

    func register(_ registration: LiveActivityRegistration) async throws {
        guard let baseURL else { throw ClientError.unavailable }
        var request = URLRequest(url: baseURL.appending(path: "v1/live-activities"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)
        try await send(request)
    }

    func end(activityID: String, installationID: UUID) async throws {
        guard let baseURL else { throw ClientError.unavailable }
        var components = URLComponents(url: baseURL.appending(path: "v1/live-activities/\(activityID)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "installationId", value: installationID.uuidString.lowercased())]
        guard let url = components?.url else { throw ClientError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try await send(request)
    }

    private func send(_ input: URLRequest) async throws {
        var request = input
        request.timeoutInterval = 20
        request.setValue("Device \(try credential())", forHTTPHeaderField: "Authorization")
        let response = try await client.send(request)
        if response.statusCode == 401 { throw ClientError.unauthorized }
        guard response.statusCode == 204 else { throw ClientError.rejected(response.statusCode) }
    }
}
