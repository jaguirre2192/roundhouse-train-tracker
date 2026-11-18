/// Local provenance for a confirmed Calendar import. Only opaque identity/revision hashes
/// and reviewed journey fields are retained; raw event content and identifiers are not saved.
public struct CalendarJourneySource: Codable, Hashable, Sendable {
    public let eventKey: String
    public let revision: String
    public let details: CalendarJourneyDetails?

    public init(eventKey: String, revision: String, details: CalendarJourneyDetails? = nil) {
        self.eventKey = eventKey
        self.revision = revision
        self.details = details
    }
}
