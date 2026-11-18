import Foundation
import TrainTrackerCore

/// What a city photo lookup is allowed to know: a station's public name and coordinates.
/// Nothing about the ticket, the rider or the trip is part of a query.
struct CityPhotoQuery: Hashable, Sendable {
    let key: String
    let stationName: String
    let latitude: Double
    let longitude: Double
    let countryCode: String
    let cityName: String?

    init?(station: Station) {
        let latitude = station.location.latitude
        let longitude = station.location.longitude
        // Without real coordinates a same-name city cannot be told apart, so no photo is shown.
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        stationName = station.displayName
        countryCode = station.countryCode.uppercased()
        cityName = nil
        key = String(format: "%@|%.3f,%.3f", station.id.rawValue, latitude, longitude)
    }

    init?(place: RailPlace) {
        let latitude = place.location.latitude
        let longitude = place.location.longitude
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        stationName = place.displayName
        countryCode = place.countryCode.uppercased()
        let suffix = " — \(JourneySearchCopy.PlacePicker.allStations)"
        let name = place.displayName.hasSuffix(suffix)
            ? String(place.displayName.dropLast(suffix.count)) : place.displayName
        cityName = place.kind == .city ? name : nil
        // Preserve station cache identities; city selections have an explicit city identity.
        let identity = place.kind == .city ? "city:\(place.id.rawValue)" : place.id.rawValue
        key = String(format: "%@|%.3f,%.3f", identity, latitude, longitude)
    }
}

/// The city a station's coordinates fall in, as reported by the system geocoder.
struct CityLocality: Codable, Hashable, Sendable {
    let locality: String
    let administrativeArea: String?
    let isoCountryCode: String?
    let country: String?
}

/// Creator, licence and source for one Wikimedia Commons photo, kept with the cached image.
struct CityPhotoCredit: Codable, Hashable, Sendable {
    let cityTitle: String
    let articleURL: URL
    let fileTitle: String
    let descriptionURL: URL
    let creator: String?
    let licenseName: String
    let licenseURL: URL?
    let imageURL: URL
}

struct CityPhoto: Hashable, Sendable {
    let credit: CityPhotoCredit
    let imageData: Data
}

/// Pure parsing and policy for turning a station into a licensed Commons city photo.
enum CityPhotoLookup {
    static let maximumCityDistanceKilometres = 35.0
    static let maximumImageCandidates = 5
    static let thumbnailWidth = 1280

    // MARK: Requests

    static func articleRequestURL(titles: [String]) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"),
            .init(name: "redirects", value: "1"),
            .init(name: "titles", value: titles.joined(separator: "|")),
            .init(name: "prop", value: "coordinates|pageimages|pageprops|images"),
            .init(name: "piprop", value: "name"),
            .init(name: "ppprop", value: "disambiguation"),
            .init(name: "coprimary", value: "primary"),
            .init(name: "imlimit", value: "max"),
        ]
        return components?.url
    }

    /// Asks Commons directly, so a file that exists only as a local non-free upload on
    /// Wikipedia comes back missing and is never used.
    static func commonsRequestURL(fileTitles: [String]) -> URL? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"),
            .init(name: "titles", value: fileTitles.joined(separator: "|")),
            .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "url|size|mime|extmetadata"),
            .init(name: "iiurlwidth", value: String(thumbnailWidth)),
            .init(name: "iiextmetadatafilter", value: "LicenseShortName|LicenseUrl|Artist|AttributionRequired|NonFree"),
        ]
        return components?.url
    }

    // MARK: City

    static func titleCandidates(for locality: CityLocality) -> [String] {
        let name = locality.locality.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let area = locality.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var titles: [String] = []
        if locality.isoCountryCode?.uppercased() == "US" {
            if ["DC", "DISTRICT OF COLUMBIA"].contains(area.uppercased()) {
                titles.append("Washington, D.C.")
            } else if let state = usStateNames[area.uppercased()] ?? usStateNames.values.first(where: { $0.caseInsensitiveCompare(area) == .orderedSame }) {
                titles.append("\(name), \(state)")
            }
        } else if locality.isoCountryCode?.uppercased() == "CA",
                  let province = canadianProvinceNames[area.uppercased()] ?? (area.isEmpty ? nil : area) {
            titles.append("\(name), \(province)")
        } else if !area.isEmpty {
            titles.append("\(name), \(area)")
        }
        titles.append(name)
        if let country = locality.country, !country.isEmpty { titles.append("\(name), \(country)") }
        var seen = Set<String>()
        return titles.filter { seen.insert($0).inserted }
    }

    struct CityArticle: Equatable, Sendable {
        let title: String
        let pageImage: String?
        let images: [String]

        var url: URL {
            URL(string: "https://en.wikipedia.org/wiki/")!
                .appending(path: title.replacingOccurrences(of: " ", with: "_"))
        }
    }

    /// The first candidate that resolves to a real, non-disambiguation article whose
    /// coordinates are near the station. A same-name city elsewhere fails the distance check.
    static func cityArticle(
        from data: Data, candidates: [String], latitude: Double, longitude: Double
    ) throws -> CityArticle? {
        let response = try JSONDecoder().decode(ArticleResponse.self, from: data)
        guard let query = response.query else { return nil }
        var resolved: [String: String] = [:]
        for step in (query.normalized ?? []) + (query.redirects ?? []) {
            resolved[step.from] = step.to
        }
        let pages = Dictionary((query.pages ?? []).map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in candidates {
            var title = candidate
            for _ in 0..<3 { title = resolved[title] ?? title }
            guard let page = pages[title], page.missing != true, page.invalid != true,
                  page.pageprops?.disambiguation == nil,
                  let coordinate = page.coordinates?.first,
                  distanceKilometres(latitude, longitude, coordinate.lat, coordinate.lon) <= maximumCityDistanceKilometres
            else { continue }
            return CityArticle(title: page.title, pageImage: page.pageimage, images: (page.images ?? []).map(\.title))
        }
        return nil
    }

    // MARK: Image

    /// The article's lead image first, then photographs whose names describe a city view.
    static func imageCandidates(for article: CityArticle) -> [String] {
        var names: [String] = []
        if let lead = article.pageImage { names.append(fileTitle(lead)) }
        let views = ["skyline", "downtown", "panorama", "cityscape", "aerial", "waterfront", "harbor", "harbour", "view"]
        names += article.images.map(fileTitle).filter { name in
            let lower = name.lowercased()
            return views.contains { lower.contains($0) }
        }
        var seen = Set<String>()
        return names
            .filter(isPhotographName)
            .filter { seen.insert($0).inserted }
            .prefix(maximumImageCandidates)
            .map { $0 }
    }

    static func acceptedPhoto(
        from data: Data, candidates: [String], article: CityArticle
    ) throws -> CityPhotoCredit? {
        let response = try JSONDecoder().decode(CommonsResponse.self, from: data)
        var resolved: [String: String] = [:]
        for step in response.query?.normalized ?? [] { resolved[step.from] = step.to }
        let pages = Dictionary((response.query?.pages ?? []).map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in candidates {
            guard let page = pages[resolved[candidate] ?? candidate], page.missing != true,
                  let credit = credit(for: page, article: article) else { continue }
            return credit
        }
        return nil
    }

    static func credit(for page: CommonsPage, article: CityArticle) -> CityPhotoCredit? {
        guard let info = page.imageinfo?.first,
              info.mime == "image/jpeg",
              let width = info.width, let height = info.height,
              Double(width) >= Double(height) * 1.25,
              let thumb = info.thumburl.flatMap(URL.init(string:)), isWikimediaUpload(thumb),
              let description = info.descriptionurl.flatMap(URL.init(string:)),
              let metadata = info.extmetadata,
              !(metadata.NonFree.map { !$0.value.isEmpty && $0.value.lowercased() != "false" } ?? false),
              let licenseName = metadata.LicenseShortName.map({ plainText($0.value) }),
              isReusableLicense(licenseName) else { return nil }
        let creator = metadata.Artist.map { plainText($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        let attributionRequired = metadata.AttributionRequired?.value.lowercased() != "false"
        if attributionRequired, creator == nil { return nil }
        return CityPhotoCredit(
            cityTitle: article.title, articleURL: article.url,
            fileTitle: page.title, descriptionURL: description,
            creator: creator, licenseName: licenseName,
            licenseURL: metadata.LicenseUrl.flatMap { URL(string: plainText($0.value)) }.flatMap(https),
            imageURL: thumb
        )
    }

    /// Public domain, CC0, CC BY and CC BY-SA can be shown with credit. Anything else, including
    /// a licence this app does not recognise, is not assumed to be reusable.
    static func isReusableLicense(_ name: String) -> Bool {
        let value = name.uppercased().replacingOccurrences(of: "  ", with: " ")
        if value == "CC0" || value.hasPrefix("CC0 ") || value.hasPrefix("PUBLIC DOMAIN") || value == "PD" || value.hasPrefix("PD-") {
            return true
        }
        return value.range(of: #"^CC BY(-SA)? (1\.0|2\.0|2\.5|3\.0|4\.0)( [A-Z]{2,})?$"#, options: .regularExpression) != nil
    }

    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: #"\(\s*talk\s*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 100 { text = String(text.prefix(99)).trimmingCharacters(in: .whitespaces) + "…" }
        return text
    }

    static func isWikimediaUpload(_ url: URL) -> Bool {
        url.scheme == "https" && ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(url.host() ?? "")
    }

    static func distanceKilometres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private static func https(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        return components.scheme == "https" ? components.url : nil
    }

    private static func fileTitle(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        return spaced.hasPrefix("File:") ? spaced : "File:\(spaced)"
    }

    private static func isPhotographName(_ title: String) -> Bool {
        let lower = title.lowercased()
        guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else { return false }
        let excluded = ["montage", "collage", "flag", "seal", "logo", "map", "locator", "coat of arms", "diagram", "wwtp"]
        return !excluded.contains { lower.contains($0) }
    }

    // MARK: Response shapes

    struct TitleStep: Decodable { let from: String; let to: String }

    struct ArticleResponse: Decodable {
        struct Query: Decodable {
            let normalized: [TitleStep]?
            let redirects: [TitleStep]?
            let pages: [Page]?
        }
        struct Page: Decodable {
            struct Coordinate: Decodable { let lat: Double; let lon: Double }
            struct Props: Decodable { let disambiguation: String? }
            struct Image: Decodable { let title: String }
            let title: String
            let missing: Bool?
            let invalid: Bool?
            let coordinates: [Coordinate]?
            let pageimage: String?
            let pageprops: Props?
            let images: [Image]?
        }
        let query: Query?
    }

    struct CommonsResponse: Decodable {
        struct Query: Decodable {
            let normalized: [TitleStep]?
            let pages: [CommonsPage]?
        }
        let query: Query?
    }

    struct CommonsPage: Decodable {
        struct Info: Decodable {
            struct Value: Decodable { let value: String }
            struct Metadata: Decodable {
                let LicenseShortName: Value?
                let LicenseUrl: Value?
                let Artist: Value?
                let AttributionRequired: Value?
                let NonFree: Value?
            }
            let width: Int?
            let height: Int?
            let mime: String?
            let thumburl: String?
            let descriptionurl: String?
            let extmetadata: Metadata?
        }
        let title: String
        let missing: Bool?
        let imageinfo: [Info]?
    }

    // MARK: Regions

    static let usStateNames: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri",
        "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey",
        "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
        "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
    ]

    static let canadianProvinceNames: [String: String] = [
        "AB": "Alberta", "BC": "British Columbia", "MB": "Manitoba", "NB": "New Brunswick",
        "NL": "Newfoundland and Labrador", "NS": "Nova Scotia", "ON": "Ontario", "PE": "Prince Edward Island",
        "QC": "Quebec", "SK": "Saskatchewan",
    ]
}
