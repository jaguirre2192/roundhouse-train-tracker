import Foundation

extension JourneyPlanResolution.Direction {
    /// Never attach another train's advisory facts by array position or ambiguous identity.
    func coverageSegment(matching segmentID: String) -> JourneyPlanResolution.Segment? {
        let matches = segments.filter { $0.segmentID == segmentID }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// What a resolved train's sources can provide, as the backend assessed it for that exact service.
///
/// Durable capability (`support`) and what this response actually contained (`availability`) are
/// separate facts: a connected feed can have nothing to report yet, and a fresh observation can
/// prove a feature for one service without establishing it for an operator or a country.
struct JourneyCoverage: Equatable, Sendable {
    enum Feature: String, CaseIterable, Sendable {
        case delays, cancellations, platforms, position
    }

    enum Support: String, Sendable {
        case connected, notProvided, unknown
    }

    enum Availability: String, Sendable {
        case observed, notObserved, unavailable
    }

    struct FeatureState: Equatable, Sendable {
        var support: Support = .unknown
        var availability: Availability = .notObserved
        /// The publisher's own evidence time. Never the time the app fetched the response.
        var observedAt: Date?

    }

    static let supportedSchemaVersion = 1
    static let detailsURL = URL(string: "https://gettraintracker.com/coverage")!

    /// Nothing is known. A missing, malformed or newer payload decodes to this, never to an error.
    static let unconfirmed = JourneyCoverage()

    /// A diagnosed provider failure for a train that could not be resolved this time.
    static let unavailable = JourneyCoverage(features: Dictionary(
        uniqueKeysWithValues: Feature.allCases.map { ($0, FeatureState(availability: .unavailable)) }
    ))

    private(set) var states: [Feature: FeatureState] = [:]
    var scopeName: String?
    var limitationCodes: [String] = []
    var detailsURL = JourneyCoverage.detailsURL

    init(
        features: [Feature: FeatureState] = [:],
        scopeName: String? = nil,
        limitationCodes: [String] = [],
        detailsURL: URL = JourneyCoverage.detailsURL
    ) {
        states = features
        self.scopeName = scopeName
        self.limitationCodes = limitationCodes
        self.detailsURL = detailsURL
    }

    subscript(feature: Feature) -> FeatureState { states[feature] ?? FeatureState() }

    /// Connected support establishes a feature; so does positive evidence in this response for
    /// the selected service. A train location counts as evidence only with the publisher's own
    /// timestamp: a point nobody dated is not an observed point. Delays legitimately have none.
    func isEstablished(_ feature: Feature) -> Bool {
        let state = self[feature]
        if state.support == .connected { return true }
        guard state.availability == .observed else { return false }
        return feature != .position || state.observedAt != nil
    }

    var established: [Feature] { Feature.allCases.filter(isEstablished) }

    /// Every feature was diagnosed unavailable in this response: an outage, not a lack of support.
    var isUnavailableNow: Bool { Feature.allCases.allSatisfy { self[$0].availability == .unavailable } }

    /// The source is known to provide none of the live features for this service.
    var isScheduleOnly: Bool {
        Feature.allCases.allSatisfy { self[$0].support == .notProvided && !isEstablished($0) }
    }
}

/// Decoding that cannot throw. Coverage is advisory: no shape of it may reject a saveable train.
extension JourneyCoverage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, scopeName, features, limitationCodes, detailsURL
    }

    private struct FeatureKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum StateKeys: String, CodingKey {
        case support, availability, observedAt
    }

    init(from decoder: any Decoder) {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              (try? container.decode(Int.self, forKey: .schemaVersion)) == Self.supportedSchemaVersion,
              let features = try? container.nestedContainer(keyedBy: FeatureKey.self, forKey: .features)
        else { return }

        for feature in Feature.allCases {
            guard let key = FeatureKey(stringValue: feature.rawValue),
                  let state = try? features.nestedContainer(keyedBy: StateKeys.self, forKey: key)
            else { continue }
            let support = (try? state.decode(String.self, forKey: .support)).flatMap(Support.init) ?? .unknown
            let availability = (try? state.decode(String.self, forKey: .availability))
                .flatMap(Availability.init) ?? .notObserved
            let observedAt = (try? state.decode(String.self, forKey: .observedAt)).flatMap(Self.timestamp)
            states[feature] = FeatureState(support: support, availability: availability, observedAt: observedAt)
        }

        scopeName = (try? container.decode(String.self, forKey: .scopeName))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        limitationCodes = ((try? container.decode([String?].self, forKey: .limitationCodes)) ?? []).compactMap { $0 }
        if let value = try? container.decode(String.self, forKey: .detailsURL),
           let url = URL(string: value), url.scheme == "https", url.host() == Self.detailsURL.host() {
            detailsURL = url
        }
    }

    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
