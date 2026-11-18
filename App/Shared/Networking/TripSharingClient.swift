import Foundation
import TrainTrackerCore

actor TripSharingClient {
    enum ClientError: Error {
        case notConfigured
        case invalidLink
        case rejected(Int)
    }

    struct SharedTrip: Decodable, Sendable {
        struct Reference: Decodable, Sendable {
            let id: String
            let source: String
            let nativeId: String
            let serviceDate: String
        }

        let trip: Reference
        let boardingStationId: String?
        let alightingStationId: String?
        let expiresAt: String
    }

    private struct CreateBody: Encodable {
        struct Reference: Encodable {
            let id: String
            let source: String
            let nativeId: String
            let serviceDate: String
        }

        let trip: Reference
        let boardingStationId: String?
        let alightingStationId: String?
    }

    private struct CreateResponse: Decodable {
        let url: URL
        let expiresAt: String
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

    func createLink(for trip: TrainTrip) async throws -> URL {
        guard let baseURL else { throw ClientError.notConfigured }
        let body = CreateBody(
            trip: .init(
                id: trip.id.rawValue,
                source: trip.source,
                nativeId: trip.id.nativeID ?? trip.id.rawValue,
                serviceDate: Self.serviceDate(trip.serviceDate)
            ),
            boardingStationId: trip.origin?.id.rawValue,
            alightingStationId: trip.destination?.id.rawValue
        )
        var request = URLRequest(url: baseURL.appending(path: "v1/shares"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let response = try await client.send(request)
        guard response.statusCode == 201 else { throw ClientError.rejected(response.statusCode) }
        return try JSONDecoder().decode(CreateResponse.self, from: response.data).url
    }

    struct ArrivalLink: Sendable {
        let url: URL
        let expiresAt: Date
    }

    enum ArrivalError: LocalizedError {
        case ended, callChanged, unavailable, busy, invalidLink
        var errorDescription: String? {
            switch self {
            case .ended: "This train has already reached that stop."
            case .callChanged: "This stop could not be matched to the train. Refresh the trip and try again."
            case .busy: "Roundhouse is busy. Try again in a minute."
            case .unavailable: "The service couldn’t verify this arrival. Try again shortly."
            case .invalidLink: "The arrival link could not be opened. Try again."
            }
        }
    }

    private struct ArrivalBody: Encodable {
        let trip: CreateBody.Reference
        let stationId: String
        let sequence: Int
        let timeZone: String?
        let note: String?
    }

    func createArrivalBoard(for trip: TrainTrip, stop: StopTime, zone: TimeZone?, note: String) async throws -> ArrivalLink {
        guard let baseURL else { throw ArrivalError.unavailable }
        // Old archives keep source-native station IDs ("BAL"); the backend's selected call uses the canonical ID.
        guard let reference = try? BackendRailReference(id: trip.id, sourceHint: trip.source),
              let station = try? BackendRailReference(id: stop.station.id, sourceHint: reference.source) else {
            throw ArrivalError.callChanged
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ArrivalBody(
            trip: .init(id: reference.id, source: reference.source, nativeId: reference.nativeID,
                        serviceDate: Self.serviceDate(trip.serviceDate)),
            stationId: station.id, sequence: stop.sequence, timeZone: zone?.identifier,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        var request = URLRequest(url: baseURL.appending(path: "v1/arrival-boards"), timeoutInterval: 18)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let response = try await client.send(request)
        switch response.statusCode {
        case 201: break
        case 410: throw ArrivalError.ended
        case 422: throw ArrivalError.callChanged
        case 429: throw ArrivalError.busy
        default: throw ArrivalError.unavailable
        }
        let link = try JSONDecoder().decode(CreateResponse.self, from: response.data)
        guard link.url.scheme == baseURL.scheme, link.url.host == baseURL.host, link.url.port == baseURL.port,
              link.url.path == "/meet", link.url.user == nil, link.url.password == nil, link.url.query == nil,
              let token = link.url.fragment, token.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              let expires = WireDate.date(from: link.expiresAt) else { throw ArrivalError.invalidLink }
        return ArrivalLink(url: link.url, expiresAt: expires)
    }

    func resolve(_ url: URL) async throws -> SharedTrip {
        guard let baseURL else { throw ClientError.notConfigured }
        guard let token = Self.token(from: url) else { throw ClientError.invalidLink }
        var request = URLRequest(
            url: baseURL.appending(path: "v1/shares/\(token)"),
            timeoutInterval: 12
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await client.send(request)
        guard response.statusCode == 200 else { throw ClientError.rejected(response.statusCode) }
        return try JSONDecoder().decode(SharedTrip.self, from: response.data)
    }

    static func token(from url: URL) -> String? {
        if url.scheme == "traintracker", url.host == "share" {
            return url.pathComponents.dropFirst().first?.removingPercentEncoding
        }
        guard url.scheme == "https", url.pathComponents.count == 3, url.pathComponents[1] == "s" else {
            return nil
        }
        return url.pathComponents[2].removingPercentEncoding
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
