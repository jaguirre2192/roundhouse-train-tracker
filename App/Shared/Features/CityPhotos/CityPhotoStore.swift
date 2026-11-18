import CoreLocation
import CryptoKit
import Foundation
import SwiftUI
import UIKit

protocol CityPhotoTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

protocol CityLocalityResolving: Sendable {
    func locality(latitude: Double, longitude: Double) async throws -> CityLocality?
}

/// Loads a licensed Wikimedia Commons photo for the city a station is in.
///
/// Requests happen only when a view asks for a city it has not seen: results are cached on
/// disk with their credit, concurrent requests for the same station share one task, and a
/// definite "no usable photo" is remembered so status polling never repeats the lookup.
actor CityPhotoStore {
    static let shared: CityPhotoStore = {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CityPhotoQAOffline") {
                return CityPhotoStore(
                    directory: FileManager.default.temporaryDirectory.appending(path: "CityPhotosOfflineQA-\(UUID().uuidString)"),
                    transport: OfflineCityPhotoTransport(), geocoder: OfflineCityLocalityResolver()
                )
            }
        #endif
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-MyTripsTicketHistoryPreview") {
                return CityPhotoStore(
                    directory: caches.appending(path: "CityPhotosTicketHistoryPreview"),
                    creditDirectory: support.appending(path: "CityPhotoCreditsTicketHistoryPreview"),
                    transport: OfflineCityPhotoTransport(), geocoder: OfflineCityLocalityResolver()
                )
            }
        #endif
        return CityPhotoStore(
            directory: caches.appending(path: "CityPhotos"),
            creditDirectory: support.appending(path: "CityPhotoCredits"),
            transport: URLSessionCityPhotoTransport(), geocoder: SystemCityLocalityResolver()
        )
    }()

    static let maximumPhotos = 24
    static let maximumStations = 200
    static let missLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let failureRetryDelay: TimeInterval = 5 * 60
    static let maximumImageBytes = 2_000_000

    private struct Index: Codable {
        struct Photo: Codable {
            var credit: CityPhotoCredit
            var fileName: String
            var lastUsed: Date
        }
        /// Station query key to Wikipedia city title, or nil when no city article matched.
        var cities: [String: String] = [:]
        var cityResolvedAt: [String: Date] = [:]
        var photos: [String: Photo] = [:]
        var missingPhotos: [String: Date] = [:]
    }

    private let directory: URL
    private let creditDirectory: URL
    private struct RecordedCredit: Codable {
        var credit: CityPhotoCredit
        var lastUsed: Date
    }
    private var creditLedger: [String: RecordedCredit]?
    private let transport: CityPhotoTransport
    private let geocoder: CityLocalityResolving
    private let now: @Sendable () -> Date
    private var index: Index?
    private var inFlight: [String: Task<CityPhoto?, Never>] = [:]
    private var failures: [String: Date] = [:]
    private(set) var networkRequestCount = 0

    init(
        directory: URL, creditDirectory: URL? = nil,
        transport: CityPhotoTransport, geocoder: CityLocalityResolving,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.creditDirectory = creditDirectory ?? directory.appending(path: "credits")
        self.transport = transport
        self.geocoder = geocoder
        self.now = now
    }

    func photo(for query: CityPhotoQuery) async -> CityPhoto? {
        if let task = inFlight[query.key] { return await task.value }
        if let cached = cachedPhoto(for: query) { return cached }
        if let failed = failures[query.key], now().timeIntervalSince(failed) < Self.failureRetryDelay { return nil }
        if isKnownMiss(query) { return nil }
        let task = Task { await self.load(query) }
        inFlight[query.key] = task
        let result = await task.value
        inFlight[query.key] = nil
        return result
    }

    /// Credits outlive the bounded image cache, including photos used before this ledger existed.
    /// Reads local files only; never touches the network.
    func cachedCredits() -> [CityPhotoCredit] {
        var ledger = loadCreditLedger()
        for entry in loadIndex().photos.values {
            let key = entry.credit.descriptionURL.absoluteString
            if ledger[key] == nil {
                ledger[key] = RecordedCredit(credit: entry.credit, lastUsed: entry.lastUsed)
            }
        }
        try? saveCredits(ledger)
        return ledger.values
            .sorted { $0.lastUsed > $1.lastUsed }
            .map(\.credit)
    }

    /// The cached photo for a station without any network request.
    func cachedPhoto(for query: CityPhotoQuery) -> CityPhoto? {
        var index = loadIndex()
        guard let title = index.cities[query.key], let entry = index.photos[title],
              let data = try? Data(contentsOf: directory.appending(path: entry.fileName)) else { return nil }
        index.photos[title]?.lastUsed = now()
        self.index = index
        // Keep attribution even when iOS later purges the downloaded image cache.
        guard (try? recordCredit(entry.credit)) != nil else { return nil }
        return CityPhoto(credit: entry.credit, imageData: data)
    }

    private func isKnownMiss(_ query: CityPhotoQuery) -> Bool {
        let index = loadIndex()
        guard let resolvedAt = index.cityResolvedAt[query.key],
              now().timeIntervalSince(resolvedAt) < Self.missLifetime else { return false }
        guard let title = index.cities[query.key] else { return true }
        if index.photos[title] != nil { return false }
        return index.missingPhotos[title].map { now().timeIntervalSince($0) < Self.missLifetime } ?? false
    }

    private func load(_ query: CityPhotoQuery) async -> CityPhoto? {
        do {
            let title: String
            let article: CityPhotoLookup.CityArticle
            let candidates: [String]
            if let cityName = query.cityName {
                // A selected city is authoritative; an airport's municipality must not replace it.
                // Use the geocoder only for disambiguating that same name, never for substituting it.
                let locality = try? await geocoder.locality(latitude: query.latitude, longitude: query.longitude)
                let countryMatches = locality?.isoCountryCode?.uppercased() == query.countryCode
                let qualified = CityPhotoLookup.titleCandidates(for: CityLocality(
                    locality: cityName,
                    administrativeArea: countryMatches ? locality?.administrativeArea : nil,
                    isoCountryCode: query.countryCode,
                    country: Locale(identifier: "en").localizedString(forRegionCode: query.countryCode)
                ))
                var seen = Set<String>()
                candidates = ([cityName] + qualified).filter { seen.insert($0).inserted }
            } else {
                guard let locality = try await geocoder.locality(latitude: query.latitude, longitude: query.longitude) else {
                    recordCity(nil, for: query)
                    return nil
                }
                candidates = CityPhotoLookup.titleCandidates(for: locality)
            }
            guard !candidates.isEmpty, let articleURL = CityPhotoLookup.articleRequestURL(titles: candidates) else {
                recordCity(nil, for: query)
                return nil
            }
            let articleData = try await fetch(articleURL)
            guard let match = try CityPhotoLookup.cityArticle(
                from: articleData, candidates: candidates, latitude: query.latitude, longitude: query.longitude
            ) else {
                recordCity(nil, for: query)
                return nil
            }
            article = match
            title = match.title
            recordCity(title, for: query)
            // Another station in the same city may already have its photo.
            if let cached = cachedPhoto(for: query) {
                return cached
            }

            let files = CityPhotoLookup.imageCandidates(for: article)
            guard !files.isEmpty, let commonsURL = CityPhotoLookup.commonsRequestURL(fileTitles: files),
                  let credit = try CityPhotoLookup.acceptedPhoto(from: try await fetch(commonsURL), candidates: files, article: article)
            else {
                recordMissingPhoto(title)
                return nil
            }
            let image = try await fetch(credit.imageURL)
            guard image.count <= Self.maximumImageBytes, UIImage(data: image) != nil else {
                recordMissingPhoto(title)
                return nil
            }
            try store(image, credit: credit)
            failures[query.key] = nil
            return CityPhoto(credit: credit, imageData: image)
        } catch {
            // Offline or a server error: show the plain header and try again later, not on every poll.
            failures[query.key] = now()
            return nil
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        networkRequestCount += 1
        return try await transport.data(from: url)
    }

    private func recordCity(_ title: String?, for query: CityPhotoQuery) {
        var index = loadIndex()
        index.cities[query.key] = title
        index.cityResolvedAt[query.key] = now()
        if index.cityResolvedAt.count > Self.maximumStations {
            let oldest = index.cityResolvedAt.sorted { $0.value < $1.value }.prefix(index.cityResolvedAt.count - Self.maximumStations)
            for (key, _) in oldest {
                index.cityResolvedAt[key] = nil
                index.cities[key] = nil
            }
        }
        save(index)
    }

    private func recordMissingPhoto(_ title: String) {
        var index = loadIndex()
        index.missingPhotos[title] = now()
        save(index)
    }

    private func store(_ image: Data, credit: CityPhotoCredit) throws {
        var index = loadIndex()
        // Migrate existing credits before any image can be evicted from the old cache.
        _ = cachedCredits()
        try recordCredit(credit)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(credit.cityTitle.utf8)).map { String(format: "%02x", $0) }.joined()
        let fileName = "\(digest.prefix(24)).jpg"
        try image.write(to: directory.appending(path: fileName), options: .atomic)
        index.photos[credit.cityTitle] = Index.Photo(credit: credit, fileName: fileName, lastUsed: now())
        index.missingPhotos[credit.cityTitle] = nil
        while index.photos.count > Self.maximumPhotos,
              let oldest = index.photos.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            try? FileManager.default.removeItem(at: directory.appending(path: oldest.value.fileName))
            index.photos[oldest.key] = nil
        }
        save(index)
    }

    private var indexURL: URL { directory.appending(path: "index.json") }
    private var creditsURL: URL { creditDirectory.appending(path: "credits.json") }

    private func loadCreditLedger() -> [String: RecordedCredit] {
        if let creditLedger { return creditLedger }
        let loaded = (try? Data(contentsOf: creditsURL))
            .flatMap { try? JSONDecoder().decode([String: RecordedCredit].self, from: $0) } ?? [:]
        creditLedger = loaded
        return loaded
    }

    private func recordCredit(_ credit: CityPhotoCredit) throws {
        var ledger = loadCreditLedger()
        ledger[credit.descriptionURL.absoluteString] = RecordedCredit(credit: credit, lastUsed: now())
        try saveCredits(ledger)
    }

    private func saveCredits(_ ledger: [String: RecordedCredit]) throws {
        try FileManager.default.createDirectory(at: creditDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: creditsURL, options: .atomic)
        creditLedger = ledger
    }

    private func loadIndex() -> Index {
        if let index { return index }
        let loaded = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
        index = loaded
        return loaded
    }

    private func save(_ index: Index) {
        self.index = index
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

extension EnvironmentValues {
    @Entry var cityPhotoStore: CityPhotoStore = .shared
}

/// An ephemeral session: no cookies or stored credentials travel with image lookups.
struct URLSessionCityPhotoTransport: CityPhotoTransport {
    /// Wikimedia's user-agent policy asks each client to identify itself with a product, a
    /// version and a way to reach whoever runs it. This is the app's own published support
    /// page (`fastlane/metadata/en-US/support_url.txt`), never a personal address.
    static let contactURL = "https://gettraintracker.com/support"

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "TrainTracker-iOS/\(version) (\(contactURL); city header photos)"
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // Wikimedia reads Api-User-Agent when a platform overrides User-Agent, so send both.
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Api-User-Agent": userAgent,
        ]
        return configuration
    }

    private static let session = URLSession(configuration: makeConfiguration())

    func data(from url: URL) async throws -> Data {
        let (data, response) = try await Self.session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

struct SystemCityLocalityResolver: CityLocalityResolving {
    func locality(latitude: Double, longitude: Double) async throws -> CityLocality? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        return try await withCheckedThrowingContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US")) { placemarks, error in
                if let error {
                    if (error as? CLError)?.code == .geocodeFoundNoResult {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let placemark = placemarks?.first, let locality = placemark.locality else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: CityLocality(
                    locality: locality, administrativeArea: placemark.administrativeArea,
                    isoCountryCode: placemark.isoCountryCode, country: placemark.country
                ))
            }
        }
    }
}

#if DEBUG
    struct OfflineCityPhotoTransport: CityPhotoTransport {
        func data(from url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    struct OfflineCityLocalityResolver: CityLocalityResolving {
        func locality(latitude: Double, longitude: Double) async throws -> CityLocality? {
            throw URLError(.notConnectedToInternet)
        }
    }
#endif
