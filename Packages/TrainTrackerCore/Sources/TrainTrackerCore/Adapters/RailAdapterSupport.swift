import Foundation

public enum RailAdapterError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier(String)
    case invalidRequest
    case invalidResponse
    case notFound
    case server(statusCode: Int)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value):
            "The rail identifier is not valid for this provider: \(value)"
        case .invalidRequest:
            "The provider request could not be created."
        case .invalidResponse:
            "The provider returned an invalid response."
        case .notFound:
            "The requested rail service was not found."
        case let .server(statusCode):
            "The provider returned HTTP \(statusCode)."
        case let .decoding(message):
            "The provider response could not be decoded: \(message)"
        }
    }
}

public enum ProviderHealthStatus: String, Codable, Sendable {
    case healthy
    case degraded
    case unavailable
}

public struct ProviderHealth: Codable, Hashable, Sendable {
    public let status: ProviderHealthStatus
    public let checkedAt: Date
    public let averageDataAge: TimeInterval?
    public let activeServices: Int?
    public let message: String?

    public init(
        status: ProviderHealthStatus,
        checkedAt: Date,
        averageDataAge: TimeInterval? = nil,
        activeServices: Int? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.checkedAt = checkedAt
        self.averageDataAge = averageDataAge
        self.activeServices = activeServices
        self.message = message
    }
}

public protocol ProviderHealthChecking: Sendable {
    func health() async throws -> ProviderHealth
}

public protocol JourneyPlanning: Sendable {
    func planJourney(
        from originID: RailIdentifier,
        to destinationID: RailIdentifier,
        at date: Date,
        arriveBy: Bool
    ) async throws -> [Journey]
}

enum RailDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        let standard = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? standard.date(from: value)
    }

    static func string(from date: Date) -> String {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.string(from: date)
    }
}

extension HTTPClient {
    func decoded<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from request: URLRequest,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Response {
        let response = try await send(request)
        switch response.statusCode {
        case 200 ..< 300:
            do {
                return try decoder.decode(type, from: response.data)
            } catch {
                throw RailAdapterError.decoding(error.localizedDescription)
            }
        case 404:
            throw RailAdapterError.notFound
        default:
            throw RailAdapterError.server(statusCode: response.statusCode)
        }
    }
}
