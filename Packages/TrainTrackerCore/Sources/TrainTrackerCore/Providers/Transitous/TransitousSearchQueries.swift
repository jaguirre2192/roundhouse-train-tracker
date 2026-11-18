import Foundation

enum TransitousSearchQueries {
    private static let stationAliases: [String: String] = [
        // Prefer the domestic Srbijavoz stop before any Latin-name feed match.
        "beograd centar": "Београд Центар",
        "beograd centar prokop": "Београд Центар",
        "belgrade centre": "Београд Центар",
        "belgrade center": "Београд Центар",
        "belgrade centar": "Београд Центар",
        "београд центар": "Београд Центар",
        "petrovaradin": "Петроварадин",
        "петроварадин": "Петроварадин",
        "montreal central": "Montréal",
        "montreal gare centrale": "Montréal",
        "southern cross": "Melbourne Southern Cross",
        "bangkok aphiwat": "Krung Thep Aphiwat",
        "krung thep aphiwat": "Bangkok",
        "new delhi": "New Delhi Railway Station",
        "casablanca voyageurs": "Casa-Voyageurs",
        "kuala lumpur sentral": "KL Sentral",
        "tel aviv central": "תל אביב מרכז",
        "tel aviv savidor": "תל אביב מרכז",
        "tel aviv savidor center": "תל אביב מרכז",
        "haifa center": "חיפה מרכז",
        "haifa center hashmona": "חיפה מרכז",
        "nahariya": "נהריה",
        "ben gurion airport": "נתבג",
        "ben gurion airport railway": "נתבג",
        "tokyo": "Tokyo",
        "shinjuku": "Shinjuku",
        "shibuya": "Shibuya",
        "shinagawa": "Shinagawa",
        "ueno": "Ueno",
        "ikebukuro": "Ikebukuro",
        "yokohama": "Yokohama",
        "kawasaki": "Kawasaki",
        "musashi kosugi": "Musashi-kosugi",
        "omiya": "Ōmiya",
        "chiba": "Chiba",
        "funabashi": "Funabashi",
        "tachikawa": "Tachikawa",
        "hachioji": "Hachiōji",
        "machida": "Machida",
        "kamakura": "Kamakura",
        "ofuna": "Ōfuna",
        "odawara": "Odawara",
        "atami": "Atami",
    ]

    static func values(for query: String) -> [String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let alias = stationAliases[aliasKey(value)], alias != value else { return [value] }
        return [alias, value]
    }

    private static func aliasKey(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+station$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
