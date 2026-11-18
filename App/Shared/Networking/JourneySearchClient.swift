import Foundation
import TrainTrackerCore

protocol JourneySearching: Sendable {
    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace]
    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage
    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution
}

struct JourneyPlanResolution: Equatable, Sendable {
    struct Direction: Equatable, Sendable {
        let fingerprint: String
        let originStationID: RailIdentifier
        let destinationStationID: RailIdentifier
        let departure: Date
        let arrival: Date
        let segments: [Segment]
    }

    struct Segment: Equatable, Sendable {
        let segmentID: String
        let trip: TrainTrip?
        let failure: Failure?
        /// Advisory. Absent, malformed or newer coverage is `.unconfirmed` and never blocks saving.
        let coverage: JourneyCoverage

        init(
            segmentID: String,
            trip: TrainTrip?,
            failure: Failure?,
            coverage: JourneyCoverage = .unconfirmed
        ) {
            self.segmentID = segmentID
            self.trip = trip
            self.failure = failure
            self.coverage = coverage
        }
    }

    struct Failure: Equatable, Sendable {
        enum Code: String, Codable, Equatable, Sendable {
            case notFound = "not_found"
            case providerUnavailable = "provider_unavailable"
        }

        let code: Code
        let message: String
    }

    let directions: [Direction]
}

actor JourneySearchClient: JourneySearching {
    enum ClientError: Error, Equatable {
        case notConfigured
        case invalidRequest
        case rejected(statusCode: Int)
        case trackingTokenExpired
        case invalidResponse
        case offline
        case timedOut
        case serviceUnavailable
        case rateLimited
    }

    private struct SearchRequest: Encodable {
        let originId: String
        let destinationId: String
        let time: String
        let arriveBy: Bool
        let maxTransfers: Int
        let cursor: String?

        private enum CodingKeys: String, CodingKey {
            case originId
            case destinationId
            case time
            case arriveBy
            case maxTransfers
            case cursor
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(originId, forKey: .originId)
            try container.encode(destinationId, forKey: .destinationId)
            try container.encode(time, forKey: .time)
            try container.encode(arriveBy, forKey: .arriveBy)
            try container.encode(maxTransfers, forKey: .maxTransfers)
            if let cursor {
                try container.encode(cursor, forKey: .cursor)
            } else {
                try container.encodeNil(forKey: .cursor)
            }
        }
    }

    private struct ResolutionRequest: Encodable {
        let trackingTokens: [String]
    }

    private struct ResolutionSnapshot: Decodable {
        struct Direction: Decodable {
            let fingerprint: String
            let originStationId: String
            let destinationStationId: String
            let departure: Date
            let arrival: Date
            let segments: [Segment]
        }

        struct Segment: Decodable {
            struct Failure: Decodable {
                let code: JourneyPlanResolution.Failure.Code
                let message: String
            }

            let segmentId: String
            let trip: BackendTripSnapshot?
            let failure: Failure?
            let coverage: JourneyCoverage

            private enum CodingKeys: String, CodingKey {
                case segmentId, trip, failure, coverage
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                segmentId = try container.decode(String.self, forKey: .segmentId)
                trip = try container.decodeIfPresent(BackendTripSnapshot.self, forKey: .trip)
                failure = try container.decodeIfPresent(Failure.self, forKey: .failure)
                coverage = (try? container.decode(JourneyCoverage.self, forKey: .coverage)) ?? .unconfirmed
            }
        }

        let directions: [Direction]
    }

    private let baseURL: URL?
    private let client: any HTTPClient

    init(
        baseURL: URL? = TrainTrackerBackendConfiguration.baseURL,
        client: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.baseURL = baseURL
        self.client = client
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] {
        guard let baseURL else { throw ClientError.notConfigured }
        guard var components = URLComponents(
            url: baseURL.appending(path: "v1/places/search"),
            resolvingAgainstBaseURL: false
        ) else { throw ClientError.invalidRequest }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "scope", value: "mainline"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { throw ClientError.invalidRequest }
        let response = try await client.send(Self.request(url: url))
        try Self.requireSuccess(response)
        return try Self.decode([RailPlace].self, from: response.data)
    }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        let time = try Self.requestTime(
            criteria.requestedTime,
            timeZoneIdentifier: criteria.timeZoneIdentifier
        )
        let body = SearchRequest(
            originId: criteria.originID.rawValue,
            destinationId: criteria.destinationID.rawValue,
            time: time,
            arriveBy: criteria.arriveBy,
            maxTransfers: criteria.maximumTransfers,
            cursor: criteria.cursor
        )
        let response = try await sendJourneyRequest(
            try postRequest(path: "v1/journeys/search", body: body)
        )
        try Self.requireSuccess(response)
        return try Self.decode(JourneySearchPage.self, from: response.data)
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        let request = try postRequest(
            path: "v1/journey-plans/resolve",
            body: ResolutionRequest(trackingTokens: trackingTokens)
        )
        let response = try await client.send(request)
        if response.statusCode == 409 { throw ClientError.trackingTokenExpired }
        try Self.requireSuccess(response)
        let snapshot = try Self.decode(ResolutionSnapshot.self, from: response.data)
        return try Self.resolution(snapshot)
    }

    private func postRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        guard let baseURL else { throw ClientError.notConfigured }
        var request = Self.request(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ClientError.invalidRequest
        }
        return request
    }

    private static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: RailRequestBudget.timeoutInterval)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func requireSuccess(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200:
            return
        case 400:
            throw ClientError.invalidRequest
        case 409:
            throw ClientError.trackingTokenExpired
        case 429:
            throw ClientError.rateLimited
        case 500, 502, 503, 504:
            throw ClientError.serviceUnavailable
        default:
            throw ClientError.rejected(statusCode: response.statusCode)
        }
    }

    private func sendJourneyRequest(_ request: URLRequest) async throws -> HTTPResponse {
        for attempt in 0...1 {
            do {
                let response = try await client.send(request)
                if attempt == 0, Self.isRetryable(statusCode: response.statusCode) {
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if attempt == 0, Self.isRetryable(error) {
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                throw Self.clientError(for: error)
            }
        }
        throw ClientError.serviceUnavailable
    }

    private static func isRetryable(statusCode: Int) -> Bool {
        [500, 502, 503, 504].contains(statusCode)
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        error.code == .timedOut || error.code == .networkConnectionLost
    }

    private static func clientError(for error: URLError) -> ClientError {
        switch error.code {
        case .timedOut:
            .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            .offline
        default:
            .serviceUnavailable
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = WireDate.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp or explicit service date."
                )
            }
            return date
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ClientError.invalidResponse
        }
    }

    private static func requestTime(_ date: Date, timeZoneIdentifier: String) throws -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw ClientError.invalidRequest
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        let value = formatter.string(from: date)
        return value.hasSuffix("Z") ? String(value.dropLast()) + "+00:00" : value
    }

    private static func resolution(_ snapshot: ResolutionSnapshot) throws -> JourneyPlanResolution {
        let directions = try snapshot.directions.map { direction in
            let segments = try direction.segments.map { segment in
                switch (segment.trip, segment.failure) {
                case let (.some(trip), .none):
                    guard trip.hasValidWireDates else { throw ClientError.invalidResponse }
                    return JourneyPlanResolution.Segment(
                        segmentID: segment.segmentId,
                        trip: trip.trip,
                        failure: nil,
                        coverage: segment.coverage
                    )
                case let (.none, .some(failure)):
                    return JourneyPlanResolution.Segment(
                        segmentID: segment.segmentId,
                        trip: nil,
                        failure: JourneyPlanResolution.Failure(
                            code: failure.code,
                            message: failure.message
                        ),
                        coverage: segment.coverage
                    )
                default:
                    throw ClientError.invalidResponse
                }
            }
            return JourneyPlanResolution.Direction(
                fingerprint: direction.fingerprint,
                originStationID: RailIdentifier(rawValue: direction.originStationId),
                destinationStationID: RailIdentifier(rawValue: direction.destinationStationId),
                departure: direction.departure,
                arrival: direction.arrival,
                segments: segments
            )
        }
        return JourneyPlanResolution(directions: directions)
    }
}

enum WireDate {
    static func date(from value: String) -> Date? {
        let bytes = Array(value.utf8)
        if bytes.count == 10 {
            guard bytes[4] == 45, bytes[7] == 45,
                  let year = number(bytes[0..<4]),
                  let month = number(bytes[5..<7]),
                  let day = number(bytes[8..<10]) else { return nil }
            return strictGregorianDate(year: year, month: month, day: day)
        }

        guard hasStrictTimestampComponents(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func hasStrictTimestampComponents(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              let year = number(bytes[0..<4]),
              let month = number(bytes[5..<7]),
              let day = number(bytes[8..<10]),
              let hour = number(bytes[11..<13]),
              let minute = number(bytes[14..<16]),
              let second = number(bytes[17..<19]) else { return false }

        let suffixStart: Int
        if bytes.last == 90 {
            suffixStart = bytes.count - 1
        } else {
            guard bytes.count >= 25 else { return false }
            suffixStart = bytes.count - 6
            guard bytes[suffixStart] == 43 || bytes[suffixStart] == 45,
                  bytes[suffixStart + 3] == 58,
                  let offsetHour = number(bytes[(suffixStart + 1)..<(suffixStart + 3)]),
                  (0...23).contains(offsetHour),
                  let offsetMinute = number(bytes[(suffixStart + 4)..<(suffixStart + 6)]),
                  (0...59).contains(offsetMinute) else { return false }
        }

        let fractional = bytes[19..<suffixStart]
        guard fractional.isEmpty || (
            fractional.count > 1
                && fractional.first == 46
                && fractional.dropFirst().allSatisfy(Self.isDigit)
        ) else { return false }

        return strictGregorianDate(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ) != nil
    }

    private static func strictGregorianDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let expected = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let date = calendar.date(from: expected) else { return nil }
        let actual = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard actual.year == year,
              actual.month == month,
              actual.day == day,
              actual.hour == hour,
              actual.minute == minute,
              actual.second == second else { return nil }
        return date
    }

    private static func number(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty, bytes.allSatisfy(isDigit) else { return nil }
        return bytes.reduce(0) { $0 * 10 + Int($1 - 48) }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }
}
