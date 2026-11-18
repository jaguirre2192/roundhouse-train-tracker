import Foundation
import XCTest
@testable import TrainTracker

final class TripSharingClientTests: XCTestCase {
    func testTokenFromUniversalLink() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/s/header.payload.signature"))

        XCTAssertEqual(TripSharingClient.token(from: url), "header.payload.signature")
    }

    func testTokenFromCustomScheme() throws {
        let url = try XCTUnwrap(URL(string: "traintracker://share/header.payload.signature"))

        XCTAssertEqual(TripSharingClient.token(from: url), "header.payload.signature")
    }

    func testTokenRejectsUnrelatedURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/privacy"))

        XCTAssertNil(TripSharingClient.token(from: url))
    }

    func testGmailCallbackAcceptsUniversalAndCustomLinks() throws {
        let canonical = try XCTUnwrap(URL(
            string: "https://api.gettraintracker.com/gmail-connected?code=test"
        ))
        let legacy = try XCTUnwrap(URL(
            string: "https://legacy-roundhouse.example.invalid/gmail-connected?code=test"
        ))
        let custom = try XCTUnwrap(URL(string: "traintracker://gmail-connected?code=test"))

        XCTAssertTrue(TicketInbox.isCallback(canonical))
        XCTAssertTrue(TicketInbox.isCallback(legacy))
        XCTAssertTrue(TicketInbox.isCallback(custom))
    }

    func testGmailCallbackRejectsLookalikeHosts() throws {
        let lookalike = try XCTUnwrap(URL(
            string: "https://api.gettraintracker.com.attacker.test/gmail-connected?code=test"
        ))

        XCTAssertFalse(TicketInbox.isCallback(lookalike))
    }

    func testAccountCallbackAcceptsCanonicalLegacyAndCustomLinks() throws {
        let canonical = try XCTUnwrap(URL(
            string: "https://api.gettraintracker.com/auth-connected?code=test"
        ))
        let legacy = try XCTUnwrap(URL(
            string: "https://legacy-roundhouse.example.invalid/auth-connected?code=test"
        ))
        let custom = try XCTUnwrap(URL(string: "traintracker://auth-connected?code=test"))

        XCTAssertTrue(AccountClient.isCallback(canonical))
        XCTAssertTrue(AccountClient.isCallback(legacy))
        XCTAssertTrue(AccountClient.isCallback(custom))
    }
}
