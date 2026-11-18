import Foundation
import TrainTrackerCore
import SwiftUI
import UIKit
import XCTest
@testable import TrainTracker

final class CityPhotoLookupTests: XCTestCase {
    func testStationWithoutRealCoordinatesGetsNoQueryAndQueryCarriesNoTripData() {
        XCTAssertNil(CityPhotoQuery(station: station(latitude: 0, longitude: 0)))
        XCTAssertNil(CityPhotoQuery(station: station(latitude: .nan, longitude: -75)))
        let query = CityPhotoQuery(station: station())
        XCTAssertEqual(query?.key, "us:amtrak:PHL|39.956,-75.182")
    }

    func testSameNameCitiesAreQualifiedByStateAndRejectedByDistance() throws {
        XCTAssertEqual(
            CityPhotoLookup.titleCandidates(for: CityLocality(locality: "Portland", administrativeArea: "ME", isoCountryCode: "US", country: "United States")),
            ["Portland, Maine", "Portland", "Portland, United States"]
        )
        XCTAssertEqual(
            CityPhotoLookup.titleCandidates(for: CityLocality(locality: "Washington", administrativeArea: "DC", isoCountryCode: "US", country: nil)).first,
            "Washington, D.C."
        )
        // Portland, Oregon's article is 4,000 km from a Maine station and "Portland" is a disambiguation page.
        let json = """
        {"query":{"pages":[
          {"title":"Portland, Maine","missing":true},
          {"title":"Portland","pageprops":{"disambiguation":""}},
          {"title":"Portland, Oregon","coordinates":[{"lat":45.52,"lon":-122.68}],"pageimage":"Portland.jpg"}
        ],"redirects":[{"from":"Portland, United States","to":"Portland, Oregon"}]}}
        """
        XCTAssertNil(try CityPhotoLookup.cityArticle(
            from: Data(json.utf8), candidates: ["Portland, Maine", "Portland", "Portland, United States"],
            latitude: 43.65, longitude: -70.26
        ))
        let oregon = try CityPhotoLookup.cityArticle(
            from: Data(json.utf8), candidates: ["Portland", "Portland, United States"],
            latitude: 45.53, longitude: -122.68
        )
        XCTAssertEqual(oregon?.title, "Portland, Oregon")
    }

    func testRedirectedAliasResolvesToTheCityArticle() throws {
        let json = """
        {"query":{"redirects":[{"from":"Philadelphia, Pennsylvania","to":"Philadelphia"}],"pages":[
          {"title":"Philadelphia","coordinates":[{"lat":39.9528,"lon":-75.1636}],"pageimage":"Philadelphia_skyline_20240528_(cropped_2-1).jpg",
           "images":[{"title":"File:Philadelphia montage.jpg"},{"title":"File:Downtown Philadelphia at night.jpg"},{"title":"File:Flag of Philadelphia.svg"}]}
        ]}}
        """
        let article = try XCTUnwrap(CityPhotoLookup.cityArticle(
            from: Data(json.utf8), candidates: ["Philadelphia, Pennsylvania", "Philadelphia"], latitude: 39.956, longitude: -75.182
        ))
        XCTAssertEqual(article.title, "Philadelphia")
        XCTAssertEqual(article.url.absoluteString, "https://en.wikipedia.org/wiki/Philadelphia")
        XCTAssertEqual(CityPhotoLookup.imageCandidates(for: article), [
            "File:Philadelphia skyline 20240528 (cropped 2-1).jpg",
            "File:Downtown Philadelphia at night.jpg",
        ])
    }

    func testOnlyRecognisedReusableLicencesWithCreditAndLandscapeCommonsJPEGsAreAccepted() throws {
        for license in ["CC BY-SA 4.0", "CC BY 2.0", "CC0", "Public domain", "CC BY-SA 3.0 DE"] {
            XCTAssertTrue(CityPhotoLookup.isReusableLicense(license), license)
        }
        for license in ["GFDL", "CC BY-NC 4.0", "CC BY-ND 2.0", "Fair use", "All rights reserved", ""] {
            XCTAssertFalse(CityPhotoLookup.isReusableLicense(license), license)
        }
        let article = CityPhotoLookup.CityArticle(title: "Philadelphia", pageImage: nil, images: [])
        let files = ["File:Missing.jpg", "File:Portrait.jpg", "File:NonFree.jpg", "File:NoCreator.jpg", "File:Skyline.jpg"]
        let credit = try XCTUnwrap(CityPhotoLookup.acceptedPhoto(from: Data(commonsJSON.utf8), candidates: files, article: article))
        XCTAssertEqual(credit.fileTitle, "File:Skyline.jpg")
        XCTAssertEqual(credit.creator, "Jane Photographer")
        XCTAssertEqual(credit.licenseName, "CC BY-SA 4.0")
        XCTAssertEqual(credit.licenseURL?.absoluteString, "https://creativecommons.org/licenses/by-sa/4.0")
        XCTAssertEqual(credit.descriptionURL.absoluteString, "https://commons.wikimedia.org/wiki/File:Skyline.jpg")
    }

    func testCreatorHTMLBecomesReadableText() {
        XCTAssertEqual(
            CityPhotoLookup.plainText(##"<a href="//commons.wikimedia.org/wiki/User:Ralf">Ralf Roletschek</a> (<a href="#"><span>talk</span></a>) &amp; team"##),
            "Ralf Roletschek & team"
        )
    }

    private var commonsJSON: String {
        func page(_ title: String, width: Int = 2000, height: Int = 1000,
                  artist: String? = "<a href=\"//commons.wikimedia.org/wiki/User:Jane\">Jane Photographer</a>",
                  nonFree: String? = nil) -> [String: Any] {
            var metadata: [String: Any] = [
                "LicenseShortName": ["value": "CC BY-SA 4.0"],
                "LicenseUrl": ["value": "https://creativecommons.org/licenses/by-sa/4.0"],
                "AttributionRequired": ["value": "true"],
            ]
            if let artist { metadata["Artist"] = ["value": artist] }
            if let nonFree { metadata["NonFree"] = ["value": nonFree] }
            return ["title": title, "imageinfo": [[
                "width": width, "height": height, "mime": "image/jpeg",
                "thumburl": "https://upload.wikimedia.org/thumb/\(title).jpg",
                "descriptionurl": "https://commons.wikimedia.org/wiki/\(title)",
                "extmetadata": metadata,
            ]]]
        }
        let pages: [[String: Any]] = [
            ["title": "File:Missing.jpg", "missing": true],
            page("File:Portrait.jpg", width: 1000, height: 1500),
            page("File:NonFree.jpg", nonFree: "true"),
            page("File:NoCreator.jpg", artist: nil),
            page("File:Skyline.jpg"),
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["query": ["pages": pages]])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Wikimedia asks API clients to identify themselves with a contact. The contact has to be the
/// app's own published support page, so this checks the header the app actually sends and that it
/// still matches the support URL in the repository's App Store metadata.
final class CityPhotoUserAgentTests: XCTestCase {
    func testWikimediaRequestsCarryThePublishedSupportContactUserAgent() async throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let published = try String(
            contentsOf: repositoryRoot.appending(path: "fastlane/metadata/en-US/support_url.txt"), encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URLSessionCityPhotoTransport.contactURL, published,
            "The user agent contact must stay the published support URL"
        )

        let configuration = URLSessionCityPhotoTransport.makeConfiguration()
        configuration.protocolClasses = [HeaderCapturingProtocol.self]
        HeaderCapturingProtocol.reset()
        let session = URLSession(configuration: configuration)
        _ = try await session.data(from: URL(string: "https://commons.wikimedia.org/w/api.php?action=query")!)

        let headers = try XCTUnwrap(HeaderCapturingProtocol.captured())
        let userAgent = try XCTUnwrap(headers["User-Agent"])
        XCTAssertEqual(headers["Api-User-Agent"], userAgent, "Both headers identify the same client")
        XCTAssertTrue(userAgent.hasPrefix("TrainTracker-iOS/"), userAgent)
        XCTAssertTrue(userAgent.contains(published), userAgent)
        XCTAssertFalse(userAgent.contains("@"), "No address, only the public support page")
        XCTAssertFalse(userAgent.localizedCaseInsensitiveContains("jorge"), "No personal information")
    }
}

/// Answers any request locally and records what was sent, so no request leaves the machine.
final class HeaderCapturingProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var headers: [String: String]?

    static func reset() { lock.withLock { headers = nil } }
    static func captured() -> [String: String]? { lock.withLock { headers } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.headers = request.allHTTPHeaderFields }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CityPhotoStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "CityPhotoStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testConcurrentRequestsShareOneLookupAndRepeatedPollsUseTheCache() async throws {
        let transport = FakeTransport()
        let geocoder = FakeGeocoder()
        let store = CityPhotoStore(directory: directory, transport: transport, geocoder: geocoder)
        let query = try XCTUnwrap(CityPhotoQuery(station: station()))

        async let first = store.photo(for: query)
        async let second = store.photo(for: query)
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0?.credit.cityTitle }, ["Philadelphia", "Philadelphia"])
        let afterFirstLoad = await store.networkRequestCount
        XCTAssertEqual(afterFirstLoad, 3, "Article, Commons metadata and one thumbnail")
        XCTAssertEqual(geocoder.calls, 1)

        for _ in 0..<5 { _ = await store.photo(for: query) }
        let afterPolls = await store.networkRequestCount
        XCTAssertEqual(afterPolls, 3, "Status refreshes for the same stop never refetch")
        XCTAssertTrue(transport.requestedURLs.allSatisfy { !$0.absoluteString.localizedCaseInsensitiveContains("ticket") })

        // A new store instance (a relaunch) reads the photo and its credit from disk.
        let relaunched = CityPhotoStore(directory: directory, transport: FakeTransport(failing: true), geocoder: FakeGeocoder())
        let cached = await relaunched.photo(for: query)
        XCTAssertEqual(cached?.credit.creator, "Jane Photographer")
        let relaunchRequests = await relaunched.networkRequestCount
        XCTAssertEqual(relaunchRequests, 0)
    }

    func testCachedCreditsListShownPhotosWithoutNetwork() async throws {
        let store = CityPhotoStore(directory: directory, transport: FakeTransport(), geocoder: FakeGeocoder())
        let empty = await store.cachedCredits()
        XCTAssertTrue(empty.isEmpty)
        let query = try XCTUnwrap(CityPhotoQuery(station: station()))
        _ = await store.photo(for: query)

        let relaunched = CityPhotoStore(directory: directory, transport: FakeTransport(failing: true), geocoder: FakeGeocoder())
        let credits = await relaunched.cachedCredits()
        XCTAssertEqual(credits.map(\.cityTitle), ["Philadelphia"])
        XCTAssertEqual(credits.first?.creator, "Jane Photographer")
        let requests = await relaunched.networkRequestCount
        XCTAssertEqual(requests, 0)
    }

    func testOfflineFailureShowsNoPhotoAndBacksOffInsteadOfRetryingEveryPoll() async throws {
        let transport = FakeTransport(failing: true)
        let store = CityPhotoStore(directory: directory, transport: transport, geocoder: FakeGeocoder())
        let query = try XCTUnwrap(CityPhotoQuery(station: station()))
        let offline = await store.photo(for: query)
        XCTAssertNil(offline)
        _ = await store.photo(for: query)
        let requests = await store.networkRequestCount
        XCTAssertEqual(requests, 1)
    }

    func testUnlicensedCityIsRememberedAsAMiss() async throws {
        let transport = FakeTransport(commons: #"{"query":{"pages":[{"title":"File:Philadelphia skyline.jpg","missing":true}]}}"#)
        let store = CityPhotoStore(directory: directory, transport: transport, geocoder: FakeGeocoder())
        let query = try XCTUnwrap(CityPhotoQuery(station: station()))
        let first = await store.photo(for: query)
        XCTAssertNil(first)
        _ = await store.photo(for: query)
        let requests = await store.networkRequestCount
        XCTAssertEqual(requests, 2, "Article and Commons once; no image download and no repeat")
    }
}

private func station(latitude: Double = 39.956, longitude: Double = -75.182) -> Station {
    Station(
        id: RailIdentifier(rawValue: "us:amtrak:PHL"), names: [.init("Philadelphia 30th Street")],
        codes: [.sourceNative: "PHL"], location: .init(latitude: latitude, longitude: longitude), countryCode: "US"
    )
}

private final class FakeGeocoder: CityLocalityResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func locality(latitude: Double, longitude: Double) async throws -> CityLocality? {
        lock.withLock { count += 1 }
        return CityLocality(locality: "Philadelphia", administrativeArea: "PA", isoCountryCode: "US", country: "United States")
    }
}

private final class FakeTransport: CityPhotoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    let failing: Bool
    let commons: String

    init(failing: Bool = false, commons: String? = nil) {
        self.failing = failing
        self.commons = commons ?? """
        {"query":{"pages":[{"title":"File:Philadelphia skyline.jpg","imageinfo":[{"width":2000,"height":1000,"mime":"image/jpeg",
          "thumburl":"https://upload.wikimedia.org/wikipedia/commons/thumb/p/ph/Philadelphia_skyline.jpg/1280px-Philadelphia_skyline.jpg",
          "descriptionurl":"https://commons.wikimedia.org/wiki/File:Philadelphia_skyline.jpg",
          "extmetadata":{"LicenseShortName":{"value":"CC BY-SA 4.0"},"Artist":{"value":"Jane Photographer"},"AttributionRequired":{"value":"true"}}}]}]}}
        """
    }

    var requestedURLs: [URL] { lock.withLock { urls } }

    func data(from url: URL) async throws -> Data {
        lock.withLock { urls.append(url) }
        try await Task.sleep(for: .milliseconds(20))
        if failing { throw URLError(.notConnectedToInternet) }
        switch url.host() {
        case "en.wikipedia.org":
            return Data("""
            {"query":{"redirects":[{"from":"Philadelphia, Pennsylvania","to":"Philadelphia"}],"pages":[
              {"title":"Philadelphia","coordinates":[{"lat":39.9528,"lon":-75.1636}],"pageimage":"Philadelphia_skyline.jpg"}]}}
            """.utf8)
        case "commons.wikimedia.org":
            return Data(commons.utf8)
        default:
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10))
            return renderer.jpegData(withCompressionQuality: 0.8) { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            }
        }
    }
}
