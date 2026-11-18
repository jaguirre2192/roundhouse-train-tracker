import Foundation

/// Bounded import spellings for specific stations accepted by place search.
/// These are station names, not provider IDs; an unknown result stays correctable.
struct ImportedStationAlias {
    let keys: Set<String>
    let stationNames: [String]
    let qualifiers: Set<String>
    let timeZoneIdentifier: String?
    let countryCode: String
    let lookupQuery: String?

    static func matching(_ names: [String]) -> Self? {
        all.first { !$0.keys.isDisjoint(with: names) }
    }

    static func lookupQuery(for name: String) -> String? {
        let station = name.split(separator: ",", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? name
        if let query = matching([ImportedStationMatcher.key(station)])?.lookupQuery { return query }
        // Providers search station labels; country/city qualifiers still constrain the
        // original imported name when ImportedStationMatcher chooses among the results.
        return name.contains(",") && !station.isEmpty ? station : nil
    }

    private init(
        _ keys: [String],
        names: [String],
        qualifiers: [String] = [],
        timeZone: String? = nil,
        countryCode: String = "US",
        lookupQuery: String? = nil
    ) {
        let specificNames = names.filter { name in
            ["Station", "Depot", "Terminal", "Square", "Penn", "Staples Mill"].contains { name.contains($0) }
        }
        self.keys = Set((keys + specificNames).map(ImportedStationMatcher.key))
        stationNames = names.map(ImportedStationMatcher.key)
        self.qualifiers = Set(qualifiers.map(ImportedStationMatcher.key))
        timeZoneIdentifier = timeZone
        self.countryCode = countryCode
        self.lookupQuery = lookupQuery
    }

    private static let all: [Self] = [
        .init(["Bruxelles-Midi", "Brussel-Zuid", "Brussels South", "Bruxelles-Midi - Brussel-Zuid"],
              names: ["Bruxelles Midi", "Brussel-Zuid", "Brussels South", "Bruxelles-Midi - Brussel-Zuid"],
              timeZone: "Europe/Brussels", countryCode: "BE"),
        // Srbijavoz publishes these stations in Cyrillic. Keep the aliases bounded
        // to the same station; Petrovaradin must not stand in for Novi Sad.
        .init(["Beograd Centar", "Belgrade Centre", "Belgrade Center", "Belgrade Centar", "Београд Центар",
               "Beograd Centar-PROKOP", "Beograd Centar Prokop"],
              names: ["Beograd Centar-PROKOP", "Београд Центар", "Beograd Centar", "Belgrade Centre",
                      "Belgrade Center", "Belgrade Centar", "Beograd Centar Prokop"],
              timeZone: "Europe/Belgrade", countryCode: "RS", lookupQuery: "Београд Центар"),
        .init(["Petrovaradin", "Петроварадин"],
              names: ["Petrovaradin", "Петроварадин"],
              timeZone: "Europe/Belgrade", countryCode: "RS", lookupQuery: "Петроварадин"),
        // SNCF's CDG 2 TGV station has several longer booking/provider spellings.
        // Keep Terminal 2/TGV explicit; a bare airport or city is not a station alias.
        // https://www.garesetconnexions.sncf/fr/gares-services/aeroport-charles-gaulle-2-tgv
        .init(["Aéroport Paris Roissy Charles de Gaulle CDG T2", "Aéroport Charles de Gaulle 2 TGV",
               "Aéroport Charles-de-Gaulle TGV", "Roissy-Airport-CDG 2", "Aéroport CDG 2 TGV",
               "Aeroport Paris CDG TGV"],
              names: ["Aéroport Charles-de-Gaulle TGV", "Aéroport Charles de Gaulle 2 TGV", "Roissy-Airport-CDG 2"],
              timeZone: "Europe/Paris", countryCode: "FR", lookupQuery: "Charles de Gaulle"),
        .init(["DC", "D C", "Washington DC", "Washington D C", "WAS"],
              names: ["Washington Union Station"], qualifiers: ["DC", "D C", "District of Columbia"]),
        .init(["New York", "NY", "NYC", "New York City", "NYP"],
              names: ["New York Penn Station", "New York Penn"], qualifiers: ["NY", "New York"]),
        .init(["BOS", "Boston South Station", "South Station"], names: ["Boston South Station", "South Station", "Boston"], qualifiers: ["MA", "Massachusetts"]),
        .init(["Philly", "Phila", "PHL", "30th Street", "Philadelphia 30th Street"],
              names: ["William H Gray III 30th Street Station", "Philadelphia 30th Street Station", "30th Street Station", "Philadelphia"],
              qualifiers: ["PA", "Pennsylvania"]),
        .init(["BAL"], names: ["Baltimore Penn Station", "Baltimore"], qualifiers: ["MD", "Maryland"]),
        .init(["BWI", "BWI Marshall Rail Station"], names: ["BWI Rail Station"], qualifiers: ["MD", "Maryland"]),
        .init(["NHV"], names: ["New Haven Union Station", "New Haven"], qualifiers: ["CT", "Connecticut"]),
        .init(["PVD"], names: ["Providence Station", "Providence"], qualifiers: ["RI", "Rhode Island"]),
        .init(["NWK"], names: ["Newark Penn Station", "Newark"], qualifiers: ["NJ", "New Jersey"]),
        .init(["RVR", "Richmond VA", "Richmond Virginia"],
              names: ["Richmond Staples Mill Road Station", "Richmond Staples Mill Road"], qualifiers: ["VA", "Virginia"]),
        .init(["ALX"], names: ["Alexandria Union Station", "Alexandria"], qualifiers: ["VA", "Virginia"]),
        .init(["WIL", "Wilmington DE", "Wilmington Delaware"],
              names: ["Wilmington Station", "Wilmington"], qualifiers: ["DE", "Delaware"]),
        .init(["CHI"], names: ["Chicago Union Station", "Chicago"], qualifiers: ["IL", "Illinois"]),
        .init(["LA", "L A", "LAX"], names: ["Los Angeles Union Station", "Los Angeles"], qualifiers: ["CA", "California"]),
        .init(["SEA", "King Street Station"], names: ["Seattle King Street Station", "Seattle"], qualifiers: ["WA", "Washington"]),
        .init(["PDX", "Portland OR", "Portland Oregon", "Portland Union Station Oregon"],
              names: ["Portland Union Station", "Portland"], qualifiers: ["OR", "Oregon"], timeZone: "America/Los_Angeles"),
        .init(["POR", "Portland ME", "Portland Maine", "Portland Union Station Maine"],
              names: ["Portland Transportation Center", "Portland"], qualifiers: ["ME", "Maine"], timeZone: "America/New_York"),
        .init(["SAC"], names: ["Sacramento Valley Station", "Sacramento"], qualifiers: ["CA", "California"]),
        .init(["SAN", "Santa Fe Depot"], names: ["San Diego Santa Fe Depot", "San Diego"], qualifiers: ["CA", "California"]),
        .init(["EMY"], names: ["Emeryville Station", "Emeryville"], qualifiers: ["CA", "California"]),
        .init(["OKJ", "Jack London Square"], names: ["Oakland Jack London Square", "Oakland"], qualifiers: ["CA", "California"]),
        .init(["ORL", "Orlando Amtrak"], names: ["Orlando Station", "Orlando"], qualifiers: ["FL", "Florida"]),
        .init(["MIA", "Miami Amtrak"], names: ["Miami Amtrak Station", "Miami"], qualifiers: ["FL", "Florida"]),
        .init(["TPA"], names: ["Tampa Union Station", "Tampa"], qualifiers: ["FL", "Florida"]),
        .init(["STL", "Saint Louis"], names: ["St Louis Gateway Transportation Center", "St Louis Gateway Station", "St Louis"], qualifiers: ["MO", "Missouri"]),
        .init(["KCY"], names: ["Kansas City Union Station", "Kansas City"], qualifiers: ["MO", "Missouri"]),
        .init(["NOL", "New Orleans"], names: ["New Orleans Union Passenger Terminal"], qualifiers: ["LA", "Louisiana"]),
    ]
}
