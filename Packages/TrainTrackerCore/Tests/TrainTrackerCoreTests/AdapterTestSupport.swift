import Foundation
import Testing
@testable import TrainTrackerCore

actor FixtureHTTPClient: HTTPClient {
    private let routes: [String: Data]
    private(set) var requests: [URLRequest] = []

    init(routes: [String: Data]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard let path = request.url?.path, let data = routes[path] else {
            return HTTPResponse(data: Data(), statusCode: 404)
        }
        return HTTPResponse(data: data, statusCode: 200)
    }
}

func fixture(_ name: String, directory: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: directory)
            ?? Bundle.module.url(forResource: name, withExtension: "json")
    )
    return try Data(contentsOf: url)
}
