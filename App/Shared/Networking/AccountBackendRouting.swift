import Foundation
import TrainTrackerCore

/// A developer can point a test build at an isolated account service. The endpoint and
/// its credential namespace are selected together before any account or alias is read.
struct AccountBackendRouting: Sendable {
    struct Route: Sendable {
        let address: URL
        let storageSuffix: String
    }

    enum RouteError: LocalizedError {
        case unavailable, invalidTestService

        var errorDescription: String? {
            switch self {
            case .unavailable: "The Roundhouse account service is temporarily unavailable."
            case .invalidTestService: "This build’s test account service is configured incorrectly."
            }
        }
    }

    static let shared: AccountBackendRouting = {
        #if DEBUG
        let testService = Bundle.main.object(forInfoDictionaryKey: "RoundhouseSandboxAccountURL") as? String
        #else
        let testService: String? = nil
        #endif
        return AccountBackendRouting(primary: TrainTrackerBackendConfiguration.baseURL, sandboxSetting: testService)
    }()

    private let primary: URL?
    private let route: Result<Route, RouteError>

    init(primary: URL?, sandboxSetting: String?) {
        self.primary = primary
        guard let primary else {
            route = .failure(.unavailable)
            return
        }
        guard let setting = sandboxSetting?.trimmingCharacters(in: .whitespacesAndNewlines), !setting.isEmpty else {
            route = .success(Route(address: primary, storageSuffix: ""))
            return
        }
        guard let endpoint = URLComponents(string: setting), endpoint.scheme == "https",
              let host = endpoint.host?.lowercased(), !host.isEmpty, host != primary.host()?.lowercased(),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.port == nil, ["", "/"].contains(endpoint.path), let address = endpoint.url else {
            route = .failure(.invalidTestService)
            return
        }
        route = .success(Route(address: address, storageSuffix: ".sandbox.\(host)"))
    }

    func manages(_ url: URL) -> Bool {
        guard let primary else { return false }
        return url.scheme == primary.scheme && url.host() == primary.host() && url.port == primary.port
    }

    var storageSuffix: String { (try? resolve().storageSuffix) ?? ".unavailable" }

    func isSelectedSandboxHost(_ host: String) -> Bool {
        guard let route = try? resolve(), !route.storageSuffix.isEmpty else { return false }
        return route.address.host()?.lowercased() == host.lowercased()
    }

    @discardableResult
    func resolve() throws -> Route { try route.get() }
}

struct AccountBackendHTTPClient: HTTPClient {
    var routing = AccountBackendRouting.shared
    var transport: any HTTPClient = URLSessionHTTPClient()

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, routing.manages(url) else { return try await transport.send(request) }
        let route = try routing.resolve()
        guard let source = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var target = URLComponents(url: route.address, resolvingAgainstBaseURL: false) else { throw AccountBackendRouting.RouteError.unavailable }
        target.percentEncodedPath = source.percentEncodedPath
        target.percentEncodedQuery = source.percentEncodedQuery
        guard let targetURL = target.url else { throw AccountBackendRouting.RouteError.unavailable }
        var scoped = request
        scoped.url = targetURL
        return try await transport.send(scoped)
    }
}
