import Foundation
import Testing
@testable import TrainTrackerCore

private struct ServiceDateCase: Sendable {
    let tripID: String
    let departure: String?
    let timeZone: String?
    let expected: String
}

@Test(arguments: [
    ServiceDateCase(tripID: "20261111_22:00_de-night", departure: "2026-11-12T01:00:00+01:00", timeZone: "Europe/Berlin", expected: "2026-11-11T00:00:00Z"),
    ServiceDateCase(tripID: "unversioned-trip", departure: "2026-11-11T23:30:00Z", timeZone: "Europe/Berlin", expected: "2026-11-12T00:00:00Z"),
    ServiceDateCase(tripID: "unversioned-trip", departure: "2026-11-12T02:30:00Z", timeZone: "America/New_York", expected: "2026-11-11T00:00:00Z"),
    ServiceDateCase(tripID: "20260230_invalid-day", departure: "2026-03-01T23:30:00Z", timeZone: "Europe/Berlin", expected: "2026-03-02T00:00:00Z"),
    ServiceDateCase(tripID: "20261001_implausible-origin", departure: "2026-11-11T23:30:00Z", timeZone: "Europe/Berlin", expected: "2026-11-12T00:00:00Z"),
    ServiceDateCase(tripID: "20261112_westward", departure: "2026-11-12T02:30:00Z", timeZone: "America/New_York", expected: "2026-11-12T00:00:00Z"),
    ServiceDateCase(tripID: "unversioned-trip", departure: "2026-11-12T00:30:00+09:00", timeZone: nil, expected: "2026-11-11T00:00:00Z"),
    ServiceDateCase(tripID: "20261111_missing-times", departure: nil, timeZone: "Europe/Berlin", expected: "2026-11-11T00:00:00Z"),
])
private func transitousServiceDateUsesOriginDayOrStationLocalDay(_ value: ServiceDateCase) throws {
    var place: [String: Any] = ["name": "Boarding", "stopId": "de-test", "lat": 52.0, "lon": 13.0]
    place["scheduledDeparture"] = value.departure
    place["tz"] = value.timeZone
    let data = try JSONSerialization.data(withJSONObject: ["place": place, "mode": "NIGHT_RAIL", "tripId": value.tripID])
    let departure = try JSONDecoder().decode(TransitousStopTimeDTO.self, from: data)
    let queryDate = try #require(RailDateParser.parse("2026-11-12T08:00:00Z"))

    let summary = TransitousMapper.summary(departure, serviceDate: queryDate, now: queryDate)

    #expect(summary.serviceDate == RailDateParser.parse(value.expected))
}
