import Foundation

public struct RailIdentifier: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(region: String, source: String, nativeID: String) {
        rawValue = "\(region):\(source):\(nativeID)"
    }

    public var region: String? { components.first.map(String.init) }
    public var source: String? { components.dropFirst().first.map(String.init) }
    public var nativeID: String? {
        guard components.count >= 3 else { return nil }
        return components.dropFirst(2).joined(separator: ":")
    }

    public var isNamespaced: Bool {
        region?.isEmpty == false && source?.isEmpty == false && nativeID?.isEmpty == false
    }

    public var description: String { rawValue }

    private var components: [Substring] {
        rawValue.split(separator: ":", omittingEmptySubsequences: false)
    }
}
