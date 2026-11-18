import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class ImportedJourneyAutoSelectionTests: XCTestCase {
    func testUniqueExactNumberNearScheduledDepartureOpensReview() throws {
        let target = option(id: "target", number: "90 32", offset: 10 * 60)
        let other = option(id: "other", number: "903", offset: 0)
        XCTAssertEqual(try preference().decision(in: [other, target]), .review(target))
    }

    func testKnownProductPrefixedProviderNumberMatchesPrintedNumericNumber() throws {
        for product in ["RJX", "RJ", "ICE", "IC", "IR", "EC", "TGV", "AVE"] {
            let target = option(id: product, number: "\(product) 19962")
            let imported = try XCTUnwrap(ImportedJourneyAutoSelection(
                trainNumber: "19962", departureTime: "2026-07-24T06:25:00Z"))
            XCTAssertEqual(imported.decision(in: [target]), .review(target), product)

            let plainTarget = option(id: "plain-\(product)", number: "19962")
            let prefixedImport = try XCTUnwrap(ImportedJourneyAutoSelection(
                trainNumber: "\(product)19962", departureTime: "2026-07-24T06:25:00Z"))
            XCTAssertEqual(prefixedImport.decision(in: [plainTarget]), .review(plainTarget), product)
        }
    }

    func testProductPrefixMatchingDoesNotEraseDifferentProductsOrOpaqueIdentifiers() throws {
        for (importedNumber, providerNumber) in [
            ("IC123", "ICE123"), ("RJ123", "RJX123"), ("123", "A123"),
            ("123", "UNKNOWN123"), ("123", "IC1234"), ("IC123", "EC123"), ("IR576", "IC576")
        ] {
            let imported = try XCTUnwrap(ImportedJourneyAutoSelection(
                trainNumber: importedNumber, departureTime: "2026-07-24T06:25:00Z"))
            XCTAssertEqual(imported.decision(in: [option(number: providerNumber)]), .choose(.noMatch))
        }
    }

    func testNumericImportStillRequiresChoiceWhenDifferentProductsShareItsNumber() throws {
        let imported = try XCTUnwrap(ImportedJourneyAutoSelection(
            trainNumber: "123", departureTime: "2026-07-24T06:25:00Z"))
        XCTAssertEqual(imported.decision(in: [option(id: "ic", number: "IC123"), option(id: "ice", number: "ICE123")]),
                       .choose(.ambiguous))
    }

    func testQualifiedImportRejectsAConflictingProductBesideANumericProviderNumber() throws {
        for (importedNumber, providerNumber, product) in [
            ("IC123", "123", "ICE"), ("RJ123", "123", "RJX"),
            ("ICE808", "808", "IC8"), ("ICE2321", "2321", "Intercity"),
            ("IC123", "123", "IC / ICE"), ("IR576", "576", "IC")
        ] {
            let imported = try XCTUnwrap(ImportedJourneyAutoSelection(
                trainNumber: importedNumber, departureTime: "2026-07-24T06:25:00Z"))
            XCTAssertEqual(imported.decision(in: [option(number: providerNumber, product: product)]),
                           .choose(.noMatch), "\(importedNumber) versus \(product) / \(providerNumber)")
        }
    }

    func testContradictoryProviderNumberAndProductRequireManualChoice() throws {
        for importedNumber in ["IC123", "123"] {
            let imported = try XCTUnwrap(ImportedJourneyAutoSelection(
                trainNumber: importedNumber, departureTime: "2026-07-24T06:25:00Z"))
            XCTAssertEqual(imported.decision(in: [option(number: "IC123", product: "ICE")]), .choose(.noMatch))
        }
    }

    func testNumericFallbackRemainsAvailableWithAgreeingOrUnspecifiedProduct() throws {
        for (importedNumber, providerNumber, product) in [
            ("IC123", "123", "IC"), ("IC808", "808", "IC8"), ("IC2321", "2321", "Intercity"),
            ("RJ123", "123", "Railjet"), ("TGV123", "123", "TGV INOUI"),
            ("ICE123", "123", "Regional train"), ("IC123", "123", ""), ("123", "ICE123", "ICE"),
            ("IR576", "576", "IR"), ("576", "IR576", "IR")
        ] {
            let imported = try XCTUnwrap(ImportedJourneyAutoSelection(
                trainNumber: importedNumber, departureTime: "2026-07-24T06:25:00Z"))
            let target = option(number: providerNumber, product: product)
            XCTAssertEqual(imported.decision(in: [target]), .review(target), "\(importedNumber) / \(product)")
        }
    }

    func testFifteenMinuteWindowIsInclusiveAndUsesScheduledDeparture() throws {
        let within = option(id: "within", offset: 15 * 60, expectedOffset: 90 * 60)
        let outside = option(id: "outside", offset: 15 * 60 + 1, expectedOffset: 0)
        let earlier = option(id: "earlier", offset: -15 * 60)
        XCTAssertEqual(try preference().decision(in: [within]), .review(within))
        XCTAssertEqual(try preference().decision(in: [earlier]), .review(earlier))
        XCTAssertEqual(try preference().decision(in: [outside]), .choose(.noMatch))
    }

    func testDifferentFingerprintsRequireChoiceEvenForSameTrainNumber() throws {
        XCTAssertEqual(
            try preference().decision(in: [option(id: "one"), option(id: "two", offset: 60)]),
            .choose(.ambiguous)
        )
    }

    func testDuplicateFingerprintCanOpenReviewOnlyWhenEveryCopyIsSafe() throws {
        let first = option(id: "first", fingerprint: "same")
        let duplicate = option(id: "duplicate", fingerprint: "same")
        XCTAssertEqual(try preference().decision(in: [first, duplicate]), .review(first))
        XCTAssertEqual(
            try preference().decision(in: [first, option(id: "cancelled", fingerprint: "same", cancelled: true)]),
            .choose(.cancelled)
        )
    }

    func testConnectionsAndWalkingSegmentsRequireChoice() throws {
        XCTAssertEqual(try preference().decision(in: [option(changes: 1)]), .choose(.connection))
        XCTAssertEqual(try preference().decision(in: [option(addWalk: true)]), .choose(.connection))
        XCTAssertEqual(try preference().decision(in: [option(addSecondRail: true)]), .choose(.connection))
    }

    func testCancellationOfTrainOrEndpointRequiresChoice() throws {
        XCTAssertEqual(try preference().decision(in: [option(cancelled: true)]), .choose(.cancelled))
        XCTAssertEqual(try preference().decision(in: [option(endpointCancelled: true)]), .choose(.cancelled))
    }

    func testUntrackableOrPartialMatchRequiresChoice() throws {
        XCTAssertEqual(try preference().decision(in: [option(trackable: false)]), .choose(.notFullyTrackable))
        XCTAssertEqual(try preference().decision(in: [option(trackableCount: 0)]), .choose(.notFullyTrackable))
        XCTAssertEqual(try preference().decision(in: [option(totalCount: 2)]), .choose(.notFullyTrackable))
        XCTAssertEqual(try preference().decision(in: [option(token: " ")]), .choose(.notFullyTrackable))
    }

    func testMissingScheduledDepartureAndInexactNumberDoNotMatch() throws {
        XCTAssertEqual(try preference().decision(in: [option(missingScheduled: true)]), .choose(.noMatch))
        XCTAssertEqual(try preference().decision(in: [option(number: "90320")]), .choose(.noMatch))
        XCTAssertEqual(try preference().decision(in: []), .choose(.noMatch))
    }

    func testDateOnlyInvalidDateAndEmptyNumberCannotRequestAutoSelection() {
        for date in [nil, "2026-07-24", "not a date"] as [String?] {
            XCTAssertNil(ImportedJourneyAutoSelection(trainNumber: "9032", departureTime: date))
        }
        for number in [nil, "", "---"] as [String?] {
            XCTAssertNil(ImportedJourneyAutoSelection(trainNumber: number, departureTime: "2026-07-24T06:25:00Z"))
        }
        XCTAssertNotNil(ImportedJourneyAutoSelection(trainNumber: "9032", departureTime: "2026-07-24T06:25:00.000Z"))
    }

    private func preference() throws -> ImportedJourneyAutoSelection {
        try XCTUnwrap(ImportedJourneyAutoSelection(trainNumber: "9032", departureTime: "2026-07-24T06:25:00Z"))
    }

    private func option(
        id: String = "match", fingerprint: String? = nil, number: String = "9032", product: String? = nil,
        offset: TimeInterval = 0, expectedOffset: TimeInterval? = nil, changes: Int = 0,
        trackable: Bool = true, cancelled: Bool = false, endpointCancelled: Bool = false,
        missingScheduled: Bool = false, addWalk: Bool = false, addSecondRail: Bool = false,
        trackableCount: Int = 1, totalCount: Int = 1, token: String = "tracking-token"
    ) -> JourneyOption {
        let time = JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z")
        let base = JourneySearchStoreFixtures.option(
            id: id, fingerprint: fingerprint ?? id,
            start: time.addingTimeInterval(offset), end: time.addingTimeInterval(offset + 7_200),
            expectedDeparture: expectedOffset.map { time.addingTimeInterval($0) },
            transferCount: changes, trainNumber: number, isTrackable: trackable
        )
        guard case let .rail(original) = base.segments[0] else { preconditionFailure("Expected rail fixture") }
        let from = JourneyCall(
            place: original.from.place, city: original.from.city,
            scheduledArrival: nil, scheduledDeparture: missingScheduled ? nil : original.from.scheduledDeparture,
            expectedArrival: nil, expectedDeparture: original.from.expectedDeparture,
            plannedPlatform: nil, expectedPlatform: nil, isCancelled: endpointCancelled
        )
        let rail = RailJourneySegment(
            id: original.id, tripID: original.tripID, serviceDate: original.serviceDate,
            operatorName: original.operatorName, product: product ?? original.product,
            trainNumber: number, trainName: nil, from: from, to: original.to,
            intermediateCalls: [], isCancelled: cancelled, isRealtime: false,
            isTrackable: trackable, untrackableReason: nil
        )
        var segments: [JourneySegment] = [.rail(rail)]
        if addWalk {
            segments.append(.walk(WalkJourneySegment(
                id: "walk", from: original.to.place, to: original.to.place,
                duration: 120, distance: 100, isStationChange: false
            )))
        }
        if addSecondRail { segments.append(.rail(original)) }
        return JourneyOption(
            id: base.id, fingerprint: base.fingerprint, startTime: base.startTime, endTime: base.endTime,
            duration: base.duration, transferCount: changes, segments: segments, badges: base.badges,
            trackability: JourneyTrackability(trackableRailSegments: trackableCount, totalRailSegments: totalCount),
            realtimeFreshness: nil, attributions: [], trackingToken: token
        )
    }
}
