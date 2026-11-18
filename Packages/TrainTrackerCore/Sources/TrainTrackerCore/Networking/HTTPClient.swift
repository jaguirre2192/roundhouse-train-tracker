import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headerFields: [String: String]

    public init(data: Data, statusCode: Int, headerFields: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headerFields = headerFields
    }

    public func value(forHTTPHeaderField field: String) -> String? {
        headerFields.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public actor URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RailAdapterError.invalidResponse
        }
        var headerFields: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headerFields[key] = value
            }
        }
        return HTTPResponse(data: data, statusCode: httpResponse.statusCode, headerFields: headerFields)
    }
}
