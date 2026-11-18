import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor RateLimitedHTTPClient: HTTPClient {
    private(set) var requestCount = 0

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requestCount += 1
        return HTTPResponse(data: Data(), statusCode: 429, headerFields: ["Retry-After": "120"])
    }
}

final class ServiceInputHardeningTests: XCTestCase {
    func testBarcodeScannerNeverFormsAnEmptyPageRange() {
        XCTAssertEqual(TicketBarcodeScanner.scannedPageNumbers(pageCount: 0), [])
        XCTAssertEqual(TicketBarcodeScanner.scannedPageNumbers(pageCount: -1), [])
        XCTAssertEqual(TicketBarcodeScanner.scannedPageNumbers(pageCount: 2), [1, 2])
        XCTAssertEqual(TicketBarcodeScanner.scannedPageNumbers(pageCount: 40), [1, 2, 3, 4, 5, 6])
    }

    func testShareImportPrefersTicketDocumentOverLeadingText() throws {
        let choice = try XCTUnwrap(ShareImportLimits.preferredAttachment(in: [
            ["public.plain-text"],
            ["public.url"],
            ["com.adobe.pdf"],
            ["public.jpeg"],
        ]))
        XCTAssertEqual(choice.index, 2)
        XCTAssertEqual(choice.kind, .pdf)
        XCTAssertEqual(ShareImportLimits.preferredAttachment(in: [["public.plain-text"]])?.kind, .text)
        XCTAssertNil(ShareImportLimits.preferredAttachment(in: [["com.example.unknown"]]))
    }

    func testShareImportRejectsOversizedFileBeforeReadingIt() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "oversized-\(UUID().uuidString).pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ShareImportLimits.maxPayloadBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try ShareImportLimits.readFile(at: url)) { error in
            XCTAssertEqual(error as? ShareImportLimits.PayloadError, .tooLarge)
        }
    }

    func testSnapshotRateLimitIsTemporaryAndPausesFurtherRequests() async throws {
        let transport = RateLimitedHTTPClient()
        let client = TripSnapshotBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")), client: transport
        )
        for _ in 0..<2 {
            do {
                _ = try await client.searchStations(query: "Paris", source: .europe)
                XCTFail("HTTP 429 must fail")
            } catch let TripSnapshotBackendClient.ClientError.rateLimited(retryAfter) {
                XCTAssertGreaterThan(retryAfter, 100)
                XCTAssertLessThanOrEqual(retryAfter, 120)
            }
        }
        let requests = await transport.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(
            TripSnapshotBackendClient.ClientError.rateLimited(retryAfter: 5).localizedDescription,
            "Roundhouse is busy right now. Try again shortly."
        )
    }
}
