import Foundation
import Testing
@testable import TrainTrackerCore

@Test func amtrakerMapsLiveTripAndStationSearch() async throws {
    let client = try FixtureHTTPClient(routes: [
        "/v3/stations": fixture("stations", directory: "Amtraker"),
        "/v3/trains/171": fixture("train", directory: "Amtraker"),
    ])
    let now = try #require(RailDateParser.parse("2026-07-20T13:40:00-04:00"))
    let adapter = AmtrakerAdapter(
        client: client,
        baseURL: try #require(URL(string: "https://fixture.test/v3")),
        now: { now }
    )

    let stations = try await adapter.searchStations(query: "New York")
    let trip = try await adapter.trip(id: RailIdentifier(rawValue: "171"), serviceDate: now)

    #expect(stations.first?.id.rawValue == "us:amtraker:NYP")
    #expect(trip.id.rawValue == "us:amtraker:171-20")
    #expect(trip.stopTimes.count == 2)
    #expect(trip.stopTimes[1].delayMinutes == 7)
    #expect(trip.stopTimes[1].displayPlatform == "4")
    #expect(trip.positions.first?.heading == 225)
    #expect(trip.alerts.count == 1)
}

@Test func amtrakerBoardUsesTheSelectedEventDateAcrossMidnight() throws {
    let stop = try JSONDecoder().decode(AmtrakerStopDTO.self, from: Data("""
    {
      "name":"Washington Union","code":"WAS",
      "schDep":"2026-07-23T00:05:00-04:00","dep":"2026-07-23T00:12:00-04:00"
    }
    """.utf8))
    let boardQueryDate = try #require(RailDateParser.parse("2026-07-22T23:55:00-04:00"))

    let serviceDate = AmtrakerMapper.boardServiceDate(
        stop,
        direction: .departures,
        fallback: boardQueryDate
    )
    let expected = try #require(RailDateParser.parse("2026-07-23T00:00:00Z"))

    #expect(serviceDate == expected)
}
