import Foundation
import Testing
@testable import TrainTrackerCore

@Suite("CalendarJourneySourceTests")
struct CalendarJourneySourceTests {
    @Test func legacySourceWithoutDetailsStillDecodes() throws {
        let json = Data(#"{"eventKey":"opaque-event-hash","revision":"opaque-revision-hash"}"#.utf8)
        let source = try JSONDecoder().decode(CalendarJourneySource.self, from: json)

        #expect(source.eventKey == "opaque-event-hash")
        #expect(source.revision == "opaque-revision-hash")
        #expect(source.details == nil)
        #expect(try JSONDecoder().decode(CalendarJourneySource.self, from: JSONEncoder().encode(source)) == source)
    }

    @Test func reviewedDetailsRoundTripWithOnlyApprovedStructuredFields() throws {
        let details = CalendarJourneyDetails(
            originName: "Washington", destinationName: "New York", trainNumber: "176",
            departureDate: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "America/New_York", isAllDay: true
        )
        let source = CalendarJourneySource(eventKey: "event-hash", revision: "revision-hash", details: details)
        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(CalendarJourneySource.self, from: encoded)
        #expect(decoded == source)
        #expect(decoded.details == details)

        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == Set(["eventKey", "revision", "details"]))
        let savedDetails = try #require(object["details"] as? [String: Any])
        #expect(Set(savedDetails.keys) == Set([
            "originName", "destinationName", "trainNumber", "departureDate", "timeZoneIdentifier", "isAllDay"
        ]))
    }

    @Test func optionalNumberAndUnspecifiedZoneRemainAbsent() throws {
        let details = CalendarJourneyDetails(
            originName: "London", destinationName: "Paris", trainNumber: nil,
            departureDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: nil, isAllDay: false
        )
        let encoded = try JSONEncoder().encode(details)
        #expect(try JSONDecoder().decode(CalendarJourneyDetails.self, from: encoded) == details)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["trainNumber"] == nil)
        #expect(object["timeZoneIdentifier"] == nil)
    }
}
