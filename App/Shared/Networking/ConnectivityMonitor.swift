import Foundation
import Network
import Observation

/// Whether the device has any network path, so My Trips can say "You're offline" instead of
/// a generic failure, and check again by itself once a path returns.
@MainActor
@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private(set) var isOffline = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.isOffline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "TrainTracker.Connectivity", qos: .utility))
    }
}
