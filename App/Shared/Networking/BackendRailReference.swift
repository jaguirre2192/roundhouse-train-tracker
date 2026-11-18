import Foundation
import TrainTrackerCore

/// The server accepts canonical identifiers and source-native identifiers from older callers.
/// Native Transitous identifiers may themselves contain colons, so splitting on colons alone
/// does not establish that an identifier carries our namespace.
struct BackendRailReference {
    let id: String
    let source: String
    let nativeID: String

    private static let regions = [
        "amtraker": "us", "transitous": "eu", "srbijavoz": "rs",
        "ekispert": "jp", "tdx": "tw", "chepe": "mx",
    ]

    init(id: RailIdentifier, sourceHint: String?) throws {
        let parts = id.rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let region = parts.first.map(String.init) ?? ""
        let provider = parts.count > 1 ? String(parts[1]) : ""
        let hasNamespace = Self.regions.values.contains(region) || Self.regions[provider] != nil
        if hasNamespace {
            // Region labels in saved journeys include country prefixes (us/ca for Transitous),
            // while discovery also uses the broader eu prefix. The source owns routing.
            guard parts.count == 3, Self.regions[provider] != nil,
                  region.count == 2, region.utf8.allSatisfy({ (97...122).contains($0) }),
                  !parts[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TripSnapshotBackendClient.ClientError.invalidRequest
            }
            self.id = id.rawValue
            source = provider
            nativeID = String(parts[2])
        } else {
            guard let sourceHint, let region = Self.regions[sourceHint],
                  !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TripSnapshotBackendClient.ClientError.invalidRequest
            }
            self.id = "\(region):\(sourceHint):\(id.rawValue)"
            source = sourceHint
            nativeID = id.rawValue
        }
    }

    static func provider(for source: RailSource?) -> String? {
        switch source {
        case .unitedStates: "amtraker"
        case .europe: "transitous"
        case nil: nil
        }
    }
}
