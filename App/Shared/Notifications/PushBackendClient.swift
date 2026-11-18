import Foundation
import TrainTrackerCore

actor PushBackendClient {
  enum ClientError: Error, LocalizedError {
    case invalidResponse
    case rejected(Int)
    case rateLimited(retryAfter: TimeInterval)
    /// The service refused this one train; other trains and the device enrollment are unaffected.
    case tripRejected(PushTripAlertRejection)

    var errorDescription: String? {
      switch self {
      case .invalidResponse: "Invalid train alert response."
      case let .rejected(status): "Train alert service returned HTTP \(status)."
      case let .rateLimited(delay): "Train alert service requested a retry after \(Int(delay)) seconds."
      case .tripRejected(.quotaExceeded): "Too many trains are watched for alerts."
      case .tripRejected(.invalidTrip): "Alerts couldn't be enabled for this train."
      case .tripRejected(.tripConflict): "Alerts for this train are already set up differently."
      }
    }
  }

  enum Platform: String, Encodable, Sendable {
    case ios
  }

  enum Environment: String, Encodable, Sendable {
    case sandbox
    case production

    /// The build's Info.plist value is the only source of truth, shared with Live Activities.
    static var configured: Environment {
      Environment(rawValue: TrainTrackerBackendConfiguration.apnsEnvironment) ?? .production
    }
  }

  struct TripWatchRequest: Sendable {
    let installationID: UUID
    let trip: TrainTrip
    /// The rider's own boarding and alighting stops. Nil falls back to the whole train.
    var boardingStationID: RailIdentifier?
    var alightingStationID: RailIdentifier?

    init(
      installationID: UUID,
      trip: TrainTrip,
      boardingStationID: RailIdentifier? = nil,
      alightingStationID: RailIdentifier? = nil
    ) {
      self.installationID = installationID
      self.trip = trip
      self.boardingStationID = boardingStationID
      self.alightingStationID = alightingStationID
    }

    init(installationID: UUID, trip: TrainTrip, range: TripAlertRange) {
      self.init(
        installationID: installationID,
        trip: trip,
        boardingStationID: range.boardingStationID,
        alightingStationID: range.alightingStationID
      )
    }
  }

  private struct DeviceBody: Encodable {
    let installationId: String
    let token: String
    let environment: Environment
    let platform: Platform
  }

  private struct SubscriptionBody: Encodable {
    struct TripReference: Encodable {
      let id: String
      let source: String
      let nativeId: String
      let serviceDate: String
    }

    struct Preferences: Encodable {
      let delayThresholdMinutes: Int
      let platformChanges: Bool
      let cancellations: Bool
      let disruptions: Bool

      /// Settings › Alerts decides what a tracked train notifies about.
      init(_ stored: PushPreferences = AlertPreference.stored()) {
        delayThresholdMinutes = stored.delayThresholdMinutes
        platformChanges = stored.notifiesPlatformChanges
        cancellations = stored.notifiesCancellations
        disruptions = stored.notifiesDisruptions
      }
    }

    let installationId: String
    let trip: TripReference
    let boardingStationId: String
    let alightingStationId: String
    let watchFrom: String
    let preferences = Preferences()
  }

  let isConfigured: Bool

  private let baseURL: URL?
  private let client: any HTTPClient
  private let credential: @Sendable () throws -> String

  init(
    baseURL: URL? = TrainTrackerBackendConfiguration.baseURL,
    client: any HTTPClient = URLSessionHTTPClient(),
    credential: @escaping @Sendable () throws -> String = {
      try PushInstallationCredentialStore.loadOrCreate()
    }
  ) {
    self.baseURL = baseURL
    self.client = client
    self.credential = credential
    isConfigured = baseURL != nil
  }

  func registerDevice(
    token: Data,
    installationID: UUID,
    environment: Environment,
    platform: Platform
  ) async throws {
    let body = DeviceBody(
      installationId: installationID.uuidString.lowercased(),
      token: token.map { String(format: "%02x", $0) }.joined(),
      environment: environment,
      platform: platform
    )
    try await send(path: "v1/devices", body: body)
  }

  func subscribe(_ request: TripWatchRequest) async throws {
    // A watch without two known stops would be dropped while looking enrolled.
    guard
      let range = TripAlertRange(
        trip: request.trip,
        boardingStationID: request.boardingStationID,
        alightingStationID: request.alightingStationID
      )
    else {
      throw ClientError.tripRejected(.invalidTrip)
    }
    let body = SubscriptionBody(
      installationId: request.installationID.uuidString.lowercased(),
      trip: .init(
        id: request.trip.id.rawValue,
        source: request.trip.source,
        nativeId: request.trip.id.nativeID ?? request.trip.id.rawValue,
        serviceDate: Self.serviceDate(request.trip.serviceDate)
      ),
      boardingStationId: range.boardingStationID.rawValue,
      alightingStationId: range.alightingStationID.rawValue,
      watchFrom: ISO8601DateFormatter().string(from: .now)
    )
    guard let response = try await post(path: "v1/subscriptions", body: body) else { return }
    switch response.statusCode {
    case 409 where Self.errorCode(in: response) == "quota_exceeded":
      throw ClientError.tripRejected(.quotaExceeded)
    case 409 where Self.errorCode(in: response) == "trip_conflict":
      throw ClientError.tripRejected(.tripConflict)
    case 400, 422:
      throw ClientError.tripRejected(.invalidTrip)
    default:
      try validate(response)
    }
  }

  func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws {
    guard let baseURL else { return }
    var components = URLComponents(
      url: baseURL.appending(path: "v1/subscriptions"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "installationId", value: installationID.uuidString.lowercased()),
      URLQueryItem(name: "tripId", value: tripID.rawValue),
    ]
    guard let url = components?.url else { throw ClientError.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    try authorize(&request)
    let response = try await client.send(request)
    try validate(response)
  }

  private func send<Body: Encodable>(path: String, body: Body) async throws {
    guard let response = try await post(path: path, body: body) else { return }
    try validate(response)
  }

  private func post<Body: Encodable>(path: String, body: Body) async throws -> HTTPResponse? {
    guard let baseURL else { return nil }
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try authorize(&request)
    request.httpBody = try JSONEncoder().encode(body)
    return try await client.send(request)
  }

  private static func errorCode(in response: HTTPResponse) -> String? {
    let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
    return object?["error"] as? String
  }

  private func validate(_ response: HTTPResponse) throws {
    guard response.statusCode != 204 else { return }
    if response.statusCode == 429 {
      let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = .gmt
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      let seconds = TimeInterval(value) ?? formatter.date(from: value)?.timeIntervalSinceNow ?? 60
      throw ClientError.rateLimited(retryAfter: seconds.isFinite ? min(max(seconds, 1), 3_600) : 60)
    }
    throw ClientError.rejected(response.statusCode)
  }

  private func authorize(_ request: inout URLRequest) throws {
    request.setValue("Device \(try credential())", forHTTPHeaderField: "Authorization")
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

/// Why the alert service refused one train while continuing with the others.
enum PushTripAlertRejection: Equatable, Sendable {
  /// The installation already watches the service's maximum number of trains.
  case quotaExceeded
  /// The train lacks usable stops or the service rejected its details.
  case invalidTrip
  /// Another installation watches the same trip ID with a different source or native ID.
  case tripConflict
}

/// The stops a train alert covers: the rider's selected journey leg when one is saved,
/// otherwise the whole train. Both stations always come from the trip's own stops.
struct TripAlertRange: Equatable, Sendable {
  let boardingStationID: RailIdentifier
  let alightingStationID: RailIdentifier

  var key: String { "\(boardingStationID.rawValue)|\(alightingStationID.rawValue)" }

  init?(trip: TrainTrip, segment: JourneyPlanSegment?) {
    if let segment, segment.kind == .rail, segment.resolvedTripID == trip.id,
       segment.unavailableReason == nil {
      let stops = RailJourneyProgress(
        trip: trip, referenceDate: .now,
        boardingPlace: segment.from, alightingPlace: segment.to
      ).stops
      if let boarding = stops.first, let alighting = stops.last {
        self.init(trip: trip, boardingStationID: boarding.station.id, alightingStationID: alighting.station.id)
        return
      }
    }
    self.init(trip: trip, boardingStationID: nil, alightingStationID: nil)
  }

  /// Requested stations are honored only when both belong to the trip in travel order.
  init?(trip: TrainTrip, boardingStationID: RailIdentifier?, alightingStationID: RailIdentifier?) {
    let stops = trip.stopTimes
    if let boardingStationID, let alightingStationID,
       let boarding = stops.firstIndex(where: { $0.station.id == boardingStationID }),
       let alighting = stops.lastIndex(where: { $0.station.id == alightingStationID }),
       boarding < alighting {
      self.boardingStationID = boardingStationID
      self.alightingStationID = alightingStationID
      return
    }
    guard stops.count >= 2, let first = stops.first, let last = stops.last else { return nil }
    self.boardingStationID = first.station.id
    self.alightingStationID = last.station.id
  }
}
