import Foundation
import UIKit
import XCTest
@testable import TrainTracker

private actor RecordingRecognizer: ImageTextRecognizing {
    let text: String?
    private(set) var calls = 0

    init(text: String?) { self.text = text }

    func recognizeText(in payload: Data) async throws -> String? {
        calls += 1
        return text
    }
}

final class ShareImportParserDetailsTests: XCTestCase {
    private func manifest(_ kind: ShareManifest.Kind) -> ShareManifest {
        ShareManifest(id: UUID(), createdAt: Date(), kind: kind, payloadFilename: "payload", suggestedFilename: nil, sizeBytes: 1)
    }

    func testTypedScreenshotTextBecomesCompleteSuggestionWithoutInventedValues() async {
        let recognizer = RecordingRecognizer(text: """
        Amtrak
        Acela 2150
        Boston South Station → New York Penn Station
        Departs Sep 22, 2026 8:05 AM
        Coach 5 Seat 14A
        Reservation number 4X7K2Q
        """)
        let manifest = manifest(.image)
        let parsed = await ShareImportParser.parseWithDetails(manifest: manifest, payload: Data([0xFF, 0xD8]), imageTextRecognizer: recognizer)
        XCTAssertEqual(parsed.suggestion.id, manifest.id)
        XCTAssertEqual(parsed.suggestion.originGuess, "Boston South Station")
        XCTAssertEqual(parsed.suggestion.destinationGuess, "New York Penn Station")
        XCTAssertEqual(parsed.suggestion.trainNumberGuess, "2150")
        XCTAssertEqual(parsed.suggestion.departureWallClock, TicketWallClock(year: 2026, month: 9, day: 22, hour: 8, minute: 5))
        XCTAssertNil(parsed.suggestion.departureDate, "A printed local time must not be converted using the device zone")
        XCTAssertFalse(parsed.suggestion.requiresDepartureTime)
        XCTAssertEqual(parsed.details.seat, "14A")
        XCTAssertEqual(parsed.details.coach, "5")
        XCTAssertEqual(parsed.details.bookingReference, "4X7K2Q")
    }

    func testMissingTimeMarksSuggestionIncompleteAndMissingDateStaysNil() async {
        let dateOnly = await ShareImportParser.parseWithDetails(
            manifest: manifest(.text), payload: Data("Amtrak train 305 Chicago to St. Louis\nTravel date: 2026-10-03".utf8)
        )
        XCTAssertEqual(dateOnly.suggestion.departureWallClock, TicketWallClock(year: 2026, month: 10, day: 3))
        XCTAssertTrue(dateOnly.suggestion.requiresDepartureTime)

        let noDate = await ShareImportParser.parseWithDetails(
            manifest: manifest(.text), payload: Data("Amtrak train 305 Chicago to St. Louis".utf8)
        )
        XCTAssertNil(noDate.suggestion.departureWallClock)
        XCTAssertNil(noDate.suggestion.departureDate)
        XCTAssertFalse(noDate.suggestion.requiresDepartureTime)
    }

    func testUnrelatedTextKeepsNoDatesOrDetails() async {
        let parsed = await ShareImportParser.parseWithDetails(
            manifest: manifest(.text), payload: Data("Dentist appointment Sep 22, 2026 8:05 AM, seat 4".utf8)
        )
        XCTAssertNil(parsed.suggestion.departureWallClock)
        XCTAssertEqual(parsed.details, TicketTextDetails())
    }

    func testBookingReferenceDigitsAreNotUsedAsTrainNumber() async {
        let parsed = await ShareImportParser.parseWithDetails(
            manifest: manifest(.text),
            payload: Data("Amtrak 612345\nBoston to New York\nBooking reference: 612345".utf8)
        )
        XCTAssertEqual(parsed.details.bookingReference, "612345")
        XCTAssertNil(parsed.suggestion.trainNumberGuess)
    }

    func testPDFTextLayerKeepsLineBoundariesForLabelledFields() async throws {
        let pdf = Self.pdf(lines: [
            "Amtrak Northeast Regional 171",
            "Departure: Washington Union Station",
            "Arrival: New York Penn Station",
            "Travel date: Sep 22, 2026 7:10 AM",
        ])
        let recognizer = RecordingRecognizer(text: "should not be used")
        let parsed = await ShareImportParser.parseWithDetails(manifest: manifest(.pdf), payload: pdf, imageTextRecognizer: recognizer)
        XCTAssertEqual(parsed.suggestion.originGuess, "Washington Union Station")
        XCTAssertEqual(parsed.suggestion.destinationGuess, "New York Penn Station")
        XCTAssertEqual(parsed.suggestion.departureWallClock, TicketWallClock(year: 2026, month: 9, day: 22, hour: 7, minute: 10))
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 0)
    }

    func testScannedPDFPagesAreRecognizedWithinPageBudget() async throws {
        let pdf = Self.pdf(lines: nil, pages: 5)
        let recognizer = RecordingRecognizer(text: "Eurostar 9032 London→Paris\nOutbound 22 Sep 2026 06:01")
        let parsed = await ShareImportParser.parseWithDetails(manifest: manifest(.pdf), payload: pdf, imageTextRecognizer: recognizer)
        let calls = await recognizer.calls
        XCTAssertEqual(calls, ShareImportParser.maxScannedPDFPages)
        XCTAssertEqual(parsed.suggestion.originGuess, "London")
        XCTAssertEqual(parsed.suggestion.trainNumberGuess, "9032")
    }

    /// Draws text lines, or blank image-only pages that have no PDF text layer.
    private static func pdf(lines: [String]?, pages: Int = 1) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for _ in 0..<pages {
                context.beginPage()
                if let lines {
                    for (index, line) in lines.enumerated() {
                        (line as NSString).draw(
                            at: CGPoint(x: 40, y: 40 + CGFloat(index) * 28),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 16)]
                        )
                    }
                } else {
                    UIColor.darkGray.setFill()
                    UIRectFill(CGRect(x: 40, y: 40, width: 300, height: 120))
                }
            }
        }
    }
}
