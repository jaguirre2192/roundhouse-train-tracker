import Foundation
import Testing
@testable import TrainTrackerCore

@Test func transitousMapsEuropeanSearchBoardTripAndJourney() async throws {
    let client = try FixtureHTTPClient(routes: [
        "/api/v1/geocode": fixture("geocode", directory: "Transitous"),
        "/api/v6/stoptimes": fixture("stoptimes", directory: "Transitous"),
        "/api/v6/trip": fixture("trip", directory: "Transitous"),
        "/api/v6/plan": fixture("plan", directory: "Transitous"),
    ])
    let now = try #require(RailDateParser.parse("2026-07-21T07:55:00Z"))
    let adapter = TransitousAdapter(
        client: client,
        baseURL: try #require(URL(string: "https://fixture.test")),
        now: { now }
    )

    let stations = try await adapter.searchStations(query: "Berlin")
    let berlin = try #require(stations.first)
    let board = try await adapter.board(stationID: berlin.id, at: now, direction: .departures)
    let trip = try await adapter.trip(id: try #require(board.first?.tripID), serviceDate: now)
    let journeys = try await adapter.planJourney(
        from: berlin.id,
        to: RailIdentifier(region: "eu", source: "transitous", nativeID: "fr-test-paris-est"),
        at: now,
        arriveBy: false
    )
    let expectedServiceDate = try #require(RailDateParser.parse("2026-07-21T00:00:00Z"))

    #expect(berlin.countryCode == "DE")
    #expect(board.first?.stopTime.didPlatformChange == true)
    #expect(board.first?.product == "ICE 9572")
    #expect(board.first?.serviceDate == expectedServiceDate)
    #expect(trip.destination?.countryCode == "FR")
    #expect(trip.stopTimes.first?.delayMinutes == 2)
    #expect(trip.routeGeometry?.source == "Transitous/MOTIS")
    #expect(trip.routeGeometry?.coordinates.count == 3)
    #expect(journeys.first?.legs.count == 1)
    #expect(journeys.first?.legs.first?.alightingStationID.nativeID == "fr-test-paris-est")
    let requests = await client.requests
    #expect(requests.allSatisfy {
        let agent = $0.value(forHTTPHeaderField: "User-Agent") ?? ""
        return agent.hasPrefix("Roundhouse/") && agent.contains("https://gettraintracker.com/support")
    })
    let modeValues = requests
        .filter { $0.url?.path == "/api/v1/geocode" || $0.url?.path == "/api/v6/stoptimes" }
        .compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        .flatMap { $0 }
        .filter { $0.name == "mode" }
        .compactMap(\.value)
    #expect(modeValues.allSatisfy { $0 == TransitousRailModes.parameter })
    let tripRequest = try #require(requests.first { $0.url?.path == "/api/v6/trip" })
    let tripQuery = URLComponents(url: try #require(tripRequest.url), resolvingAgainstBaseURL: false)?.queryItems
    #expect(tripQuery?.first(where: { $0.name == "detailedLegs" })?.value == "true")
}

@Test func transitousFiltersUrbanModesAndExpandsJapaneseEnglishStationNames() {
    #expect(TransitousRailModes.isMainline("HIGHSPEED_RAIL"))
    #expect(TransitousRailModes.isMainline("REGIONAL_RAIL"))
    #expect(!TransitousRailModes.isMainline("SUBWAY"))
    #expect(!TransitousRailModes.isMainline("TRAM"))
    #expect(!TransitousRailModes.isMainline("SUBURBAN"))
    #expect(TransitousSearchQueries.values(for: "Tokyo Station") == ["Tokyo", "Tokyo Station"])
    #expect(TransitousSearchQueries.values(for: "Shinjuku station").first == "Shinjuku")
    #expect(TransitousSearchQueries.values(for: "Montreal Central").first == "Montréal")
    #expect(TransitousSearchQueries.values(for: "Tel Aviv Savidor Center").first == "תל אביב מרכז")
    #expect(TransitousSearchQueries.values(for: "Ben Gurion Airport station").first == "נתבג")
    #expect(TransitousMainlineScope.acceptsStation(nativeID: "ca-Viarail_226", countryCode: "CA"))
    #expect(!TransitousMainlineScope.acceptsStation(nativeID: "ca-qc-exo_1000", countryCode: "CA"))
    #expect(!TransitousMainlineScope.acceptsStation(
        nativeID: "fr-reseau-urbain-et-interurbain-dile-de-france-mobilites_IDFM:73626",
        countryCode: "FR"
    ))
    #expect(TransitousMainlineScope.acceptsStation(
        nativeID: "ch-opentransportdataswiss26_Parent8768600",
        countryCode: "FR"
    ))
    #expect(TransitousMainlineScope.acceptsDeparture(
        tripID: "20260721_au-vic-regional-trains_8863",
        routeLongName: "Warrnambool - Melbourne"
    ))
    #expect(!TransitousMainlineScope.acceptsDeparture(
        tripID: "20260721_au-nsw-sydney-trains_T2",
        routeLongName: "Inner West"
    ))
}

@Test func transitousSerbianStationSearchPrefersDomesticCyrillicQueries() {
    for query in ["Beograd Centar", "Belgrade Centre", "Belgrade Center", "Belgrade Centar",
                  "Beograd Centar-PROKOP", "Beograd Centar Prokop"] {
        #expect(TransitousSearchQueries.values(for: query) == ["Београд Центар", query])
    }
    #expect(TransitousSearchQueries.values(for: "Petrovaradin") == ["Петроварадин", "Petrovaradin"])
    #expect(TransitousSearchQueries.values(for: "Београд Центар") == ["Београд Центар"])
    #expect(TransitousSearchQueries.values(for: "Петроварадин") == ["Петроварадин"])
    #expect(TransitousSearchQueries.values(for: "  Belgrade Center Station  ") == ["Београд Центар", "Belgrade Center Station"])
}

@Test func transitousSerbianStationAliasesPreserveDistinctStations() {
    for query in ["Novi Sad", "Нови Сад", "Belgrade", "Beograd", "Београд", "Beograd Dunav", "Београд Дунав"] {
        #expect(TransitousSearchQueries.values(for: query) == [query])
    }
}

@Test func transitousBoardKeepsTheOriginServiceDateAcrossMidnight() throws {
    let value = try JSONDecoder().decode(TransitousStopTimeDTO.self, from: Data("""
    {
      "place":{
        "name":"Berlin Hbf","stopId":"de-test-berlin-hbf","lat":52.525,"lon":13.369,
        "tz":"Europe/Berlin","scheduledDeparture":"2026-07-23T00:12:00Z"
      },
      "mode":"HIGHSPEED_RAIL",
      "headsign":"Amsterdam Centraal",
      "tripId":"20260722_de-night-1234"
    }
    """.utf8))
    let boardQueryDate = try #require(RailDateParser.parse("2026-07-22T23:55:00Z"))

    let summary = TransitousMapper.summary(
        value,
        serviceDate: boardQueryDate,
        now: boardQueryDate
    )
    let expected = try #require(RailDateParser.parse("2026-07-22T00:00:00Z"))

    #expect(summary.serviceDate == expected)
}

@Test func transitousKeepsOnlyTheBoardedJapaneseRun() throws {
    let selected = "20260721_17:44_jp-tokyo-rail_JR-East.Yamanote.1730G.Weekday"
    let data = Data("""
    {
      "startTime":"2026-07-21T08:44:00Z",
      "endTime":"2026-07-21T10:58:00Z",
      "duration":8040,
      "transfers":0,
      "legs":[
        {
          "mode":"REGIONAL_RAIL",
          "tripId":"\(selected)",
          "agencyName":"JR East",
          "routeShortName":"JY",
          "tripShortName":"1730G",
          "from":{"name":"Ōsaki","stopId":"jp-tokyo-rail_Osaki","lat":35.619,"lon":139.728,"tz":"Asia/Tokyo","scheduledDeparture":"2026-07-21T08:44:00Z"},
          "intermediateStops":[{"name":"Tokyo","stopId":"jp-tokyo-rail_Tokyo","lat":35.681,"lon":139.767,"tz":"Asia/Tokyo","scheduledArrival":"2026-07-21T09:01:00Z","scheduledDeparture":"2026-07-21T09:01:00Z"}],
          "to":{"name":"Ōsaki","stopId":"jp-tokyo-rail_Osaki","lat":35.619,"lon":139.728,"tz":"Asia/Tokyo","scheduledArrival":"2026-07-21T09:50:00Z"}
        },
        {
          "mode":"REGIONAL_RAIL",
          "tripId":"20260721_18:52_jp-tokyo-rail_JR-East.Yamanote.1830G.Weekday",
          "agencyName":"JR East",
          "routeShortName":"JY",
          "tripShortName":"1830G",
          "from":{"name":"Ōsaki","stopId":"jp-tokyo-rail_Osaki","lat":35.619,"lon":139.728,"scheduledDeparture":"2026-07-21T09:52:00Z"},
          "to":{"name":"Ōsaki","stopId":"jp-tokyo-rail_Osaki","lat":35.619,"lon":139.728,"scheduledArrival":"2026-07-21T10:58:00Z"}
        }
      ]
    }
    """.utf8)
    let itinerary = try JSONDecoder().decode(TransitousItineraryDTO.self, from: data)
    let serviceDate = try #require(RailDateParser.parse("2026-07-21T00:00:00Z"))
    let trip = try TransitousMapper.trip(
        itinerary,
        nativeTripID: selected,
        serviceDate: serviceDate,
        now: serviceDate
    )

    #expect(trip.stopTimes.map(\.station.displayName) == ["Ōsaki", "Tokyo", "Ōsaki"])
}
