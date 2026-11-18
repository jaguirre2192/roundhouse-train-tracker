import Foundation
import TrainTrackerCore
@testable import TrainTracker

/// Replays exact captured LI planner/resolution/snapshot payloads at the HTTP boundary.
/// No fixture URL is contacted, and no current provider availability is asserted.
actor SplitCallFixtureHTTPClient: HTTPClient {
    private let places: [String: Data]
    private let page: Data
    private let resolution: Data
    private let snapshots: [String: Data]
    private let trackingToken: String
    private(set) var searchedBodies: [Data] = []
    private(set) var refreshedIDs: [String] = []

    init(data: Data) throws {
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        places = try Dictionary(uniqueKeysWithValues: (fixture["places"] as! [[String: Any]]).map {
            ($0["query"] as! String, try JSONSerialization.data(withJSONObject: $0["places"]!))
        })
        let searchPage = fixture["page"] as! [String: Any]
        page = try JSONSerialization.data(withJSONObject: searchPage)
        resolution = try JSONSerialization.data(withJSONObject: fixture["resolution"]!)
        snapshots = try Dictionary(uniqueKeysWithValues: (fixture["snapshots"] as! [[String: Any]]).map {
            ($0["id"] as! String, try JSONSerialization.data(withJSONObject: $0))
        })
        guard let options = searchPage["options"] as? [[String: Any]],
              let token = options.first?["trackingToken"] as? String else { throw URLError(.cannotDecodeContentData) }
        trackingToken = token
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let data: Data
        switch request.url?.path {
        case "/v1/places/search":
            guard let result = places[value("q") ?? ""] else { throw URLError(.badURL) }
            data = result
        case "/v1/journeys/search":
            guard let body = request.httpBody else { throw URLError(.badServerResponse) }
            searchedBodies.append(body)
            data = page
        case "/v1/journey-plans/resolve":
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            guard body["trackingTokens"] as? [String] == [trackingToken] else { throw URLError(.badServerResponse) }
            data = resolution
        case "/v1/trips/snapshot":
            guard let id = value("id"), let snapshot = snapshots[id],
                  value("source") == "transitous", value("nativeId") == RailIdentifier(rawValue: id).nativeID,
                  value("serviceDate") == "2026-11-13" else { throw URLError(.badServerResponse) }
            refreshedIDs.append(id)
            data = snapshot
        default:
            throw URLError(.unsupportedURL)
        }
        return HTTPResponse(data: data, statusCode: 200)
    }
}
