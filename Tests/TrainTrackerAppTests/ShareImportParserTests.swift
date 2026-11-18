import Foundation
import XCTest
@testable import TrainTracker

private struct FakeImageTextRecognizer: ImageTextRecognizing {
    let text: String?
    func recognizeText(in payload: Data) async throws -> String? { text }
}

final class ShareImportParserTests: XCTestCase {
    func testPlainTextRouteIsExtracted() async {
        let manifest = ShareManifest(
            id: UUID(),
            createdAt: Date(),
            kind: .text,
            payloadFilename: "ignored",
            suggestedFilename: nil,
            sizeBytes: 0
        )
        let payload = Data("Your Amtrak booking: Chicago to St. Louis, Train 305".utf8)

        let suggestion = await ShareImportParser.parse(manifest: manifest, payload: payload)

        XCTAssertEqual(suggestion.originGuess, "Chicago")
        XCTAssertEqual(suggestion.destinationGuess, "St. Louis")
        XCTAssertEqual(suggestion.trainNumberGuess, "305")
        XCTAssertTrue(suggestion.evidence.contains("Mentions Amtrak"))
    }

    func testUnrelatedTextProducesNoRouteGuess() async {
        let manifest = ShareManifest(
            id: UUID(),
            createdAt: Date(),
            kind: .text,
            payloadFilename: "ignored",
            suggestedFilename: nil,
            sizeBytes: 0
        )
        let payload = Data("Don't forget to buy milk".utf8)

        let suggestion = await ShareImportParser.parse(manifest: manifest, payload: payload)

        XCTAssertNil(suggestion.originGuess)
        XCTAssertNil(suggestion.destinationGuess)
        XCTAssertTrue(suggestion.evidence.isEmpty)
    }

    func testEmailMessageUsesSubjectAndBody() async {
        let manifest = ShareManifest(
            id: UUID(),
            createdAt: Date(),
            kind: .emailMessage,
            payloadFilename: "ignored",
            suggestedFilename: "ticket.eml",
            sizeBytes: 0
        )
        let raw = """
        From: rail@example.test
        Subject: Your VIA Rail booking: Toronto to Ottawa

        Thanks for booking with VIA Rail.
        """
        let suggestion = await ShareImportParser.parse(manifest: manifest, payload: Data(raw.utf8))

        XCTAssertEqual(suggestion.originGuess, "Toronto")
        XCTAssertEqual(suggestion.destinationGuess, "Ottawa")
    }

    func testImagePayloadWithNoRecognizedTextHasNoAutomaticRouteGuess() async {
        let manifest = ShareManifest(
            id: UUID(),
            createdAt: Date(),
            kind: .image,
            payloadFilename: "ignored",
            suggestedFilename: nil,
            sizeBytes: 0
        )

        let suggestion = await ShareImportParser.parse(
            manifest: manifest,
            payload: Data([0xFF, 0xD8, 0xFF]),
            imageTextRecognizer: FakeImageTextRecognizer(text: nil)
        )

        XCTAssertNil(suggestion.originGuess)
        XCTAssertNil(suggestion.destinationGuess)
        XCTAssertEqual(suggestion.sourceDescription, "Shared image")
    }

    func testImagePayloadMapsRecognizedTextThroughRouteHeuristics() async {
        let manifest = ShareManifest(
            id: UUID(),
            createdAt: Date(),
            kind: .image,
            payloadFilename: "ignored",
            suggestedFilename: nil,
            sizeBytes: 0
        )

        let suggestion = await ShareImportParser.parse(
            manifest: manifest,
            payload: Data([0xFF, 0xD8, 0xFF]),
            imageTextRecognizer: FakeImageTextRecognizer(
                text: "Amtrak Acela e-ticket: Boston to New York, Train #2151"
            )
        )

        XCTAssertEqual(suggestion.originGuess, "Boston")
        XCTAssertEqual(suggestion.destinationGuess, "New York")
        XCTAssertEqual(suggestion.trainNumberGuess, "2151")
        XCTAssertEqual(suggestion.confidence, .high)
    }

    func testImageRecognitionFailureIsTreatedAsNoText() async {
        struct ThrowingRecognizer: ImageTextRecognizing {
            struct Failure: Error {}
            func recognizeText(in payload: Data) async throws -> String? { throw Failure() }
        }
        let manifest = ShareManifest(
            id: UUID(),
            createdAt: Date(),
            kind: .image,
            payloadFilename: "ignored",
            suggestedFilename: nil,
            sizeBytes: 0
        )

        let suggestion = await ShareImportParser.parse(
            manifest: manifest,
            payload: Data([0xFF, 0xD8, 0xFF]),
            imageTextRecognizer: ThrowingRecognizer()
        )

        XCTAssertNil(suggestion.originGuess)
        XCTAssertTrue(suggestion.evidence.isEmpty)
    }

    func testEmailPreservesSeparateDepartureAndArrivalFields() async {
        let manifest = ShareManifest(
            id: UUID(), createdAt: Date(), kind: .emailMessage,
            payloadFilename: "ignored", suggestedFilename: "ticket.eml", sizeBytes: 0
        )
        let raw = """
        From: rail@example.test
        Subject: Amtrak Northeast Regional 176 booking

        Departure: Washington Union Station
        Arrival: New York Penn Station
        Seat: 14A
        Address: 123 Example Street
        """
        let result = await ShareImportParser.parse(manifest: manifest, payload: Data(raw.utf8))

        XCTAssertEqual(result.originGuess, "Washington Union Station")
        XCTAssertEqual(result.destinationGuess, "New York Penn Station")
        XCTAssertEqual(result.trainNumberGuess, "176")
        XCTAssertEqual(result.confidence, .high)
    }

    func testSharedCompactArrowAndOperatorNumberAreParsed() async {
        let manifest = ShareManifest(
            id: UUID(), createdAt: Date(), kind: .text,
            payloadFilename: "ignored", suggestedFilename: nil, sizeBytes: 0
        )
        let result = await ShareImportParser.parse(
            manifest: manifest, payload: Data("Eurostar 9032 London→Paris".utf8)
        )

        XCTAssertEqual(result.originGuess, "London")
        XCTAssertEqual(result.destinationGuess, "Paris")
        XCTAssertEqual(result.trainNumberGuess, "9032")
    }

    func testSharedOperatorProjectMeetingHasNoRouteSuggestion() async {
        let manifest = ShareManifest(
            id: UUID(), createdAt: Date(), kind: .text,
            payloadFilename: "ignored", suggestedFilename: nil, sizeBytes: 0
        )
        let result = await ShareImportParser.parse(
            manifest: manifest, payload: Data("Amtrak project meeting".utf8)
        )

        XCTAssertNil(result.originGuess)
        XCTAssertNil(result.destinationGuess)
        XCTAssertNil(result.confidence)
        XCTAssertTrue(result.evidence.isEmpty)
    }
}
