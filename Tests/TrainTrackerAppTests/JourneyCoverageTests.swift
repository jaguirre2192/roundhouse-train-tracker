import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyCoverageTests: XCTestCase {
    typealias Feature = JourneyCoverage.Feature
    typealias State = JourneyCoverage.FeatureState

    @MainActor
    func testCoverageMatchesExactUniqueSegmentIdentityWithoutOrderFallback() {
        let resolution = Self.resolution(outbound: journeyOutboundOption(), coverages: [Self.connected, .unconfirmed])
        let original = resolution.directions[0]
        let answer = original.segments[0]
        let reordered = JourneyPlanResolution.Direction(
            fingerprint: original.fingerprint, originStationID: original.originStationID,
            destinationStationID: original.destinationStationID, departure: original.departure,
            arrival: original.arrival, segments: Array(original.segments.reversed())
        )
        XCTAssertEqual(reordered.coverageSegment(matching: answer.segmentID), answer)
        XCTAssertNil(reordered.coverageSegment(matching: "a-different-train"))
        let ambiguous = JourneyPlanResolution.Direction(
            fingerprint: original.fingerprint, originStationID: original.originStationID,
            destinationStationID: original.destinationStationID, departure: original.departure,
            arrival: original.arrival, segments: [answer, answer]
        )
        XCTAssertNil(ambiguous.coverageSegment(matching: answer.segmentID))
    }

    // MARK: Decoding never throws and never over-claims

    func testContractExampleKeepsSupportAndObservationSeparate() throws {
        let coverage = try decode(Self.contractExample)

        XCTAssertEqual(coverage[.position].support, .connected)
        XCTAssertEqual(coverage[.position].availability, .observed)
        XCTAssertEqual(
            coverage[.position].observedAt,
            ISO8601DateFormatter().date(from: "2026-11-13T22:49:45Z")
        )
        XCTAssertEqual(coverage[.delays].support, .unknown)
        XCTAssertEqual(coverage[.delays].availability, .notObserved)
        XCTAssertNil(coverage[.delays].observedAt)
        XCTAssertEqual(coverage.scopeName, "PID regional rail")
        XCTAssertEqual(coverage.limitationCodes, ["regionalScope", "exactServiceRequired"])
        XCTAssertEqual(coverage.detailsURL.absoluteString, "https://gettraintracker.com/coverage")
        XCTAssertEqual(coverage.established, [.position])
    }

    func testMalformedNewerAndEmptyPayloadsBecomeUnconfirmed() throws {
        let payloads = [
            "{}", "null", "[]", "\"connected\"", "42",
            #"{"schemaVersion":2,"features":{"delays":{"support":"connected","availability":"observed"}}}"#,
            #"{"schemaVersion":"1","features":{"delays":{"support":"connected"}}}"#,
            #"{"schemaVersion":1,"features":"all"}"#,
            #"{"features":{"delays":{"support":"connected"}}}"#,
        ]
        for payload in payloads {
            XCTAssertEqual(try decode(payload), .unconfirmed, payload)
        }
    }

    func testUnknownEnumsAndWrongTypesDegradePerFeatureWithoutLosingTheRest() throws {
        let coverage = try decode(#"""
        {"schemaVersion":1,"scopeName":"   ","limitationCodes":["a",null,"b"],
         "detailsURL":"https://example.com/phish",
         "features":{
           "delays":{"support":"guaranteed","availability":"streaming","observedAt":"yesterday"},
           "cancellations":{"support":7,"availability":null},
           "platforms":"yes",
           "position":{"support":"notProvided","availability":"notObserved","observedAt":null},
           "wifi":{"support":"connected","availability":"observed"}
         }}
        """#)

        XCTAssertEqual(coverage[.delays], State())
        XCTAssertEqual(coverage[.cancellations], State())
        XCTAssertEqual(coverage[.platforms], State())
        XCTAssertEqual(coverage[.position].support, .notProvided)
        XCTAssertNil(coverage.scopeName)
        XCTAssertEqual(coverage.limitationCodes, ["a", "b"])
        XCTAssertEqual(coverage.detailsURL, JourneyCoverage.detailsURL, "Only our own readable page may be linked")
        XCTAssertTrue(coverage.established.isEmpty)
    }

    // MARK: Classification

    func testUnconfirmedIsNeitherScheduleOnlyNorLive() {
        let disclosure = JourneyCoverageDisclosure(coverage: .unconfirmed)
        XCTAssertEqual(disclosure.kind, .unconfirmed)
        XCTAssertEqual(disclosure.title, "Live coverage not confirmed")
        XCTAssertTrue(disclosure.isGap)
    }

    func testScheduleOnlyNeedsEveryFeatureKnownNotProvided() {
        var states = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, State(support: .notProvided)) })
        XCTAssertEqual(JourneyCoverageDisclosure(coverage: JourneyCoverage(features: states)).kind, .scheduleOnly)

        states[.platforms] = State(support: .unknown)
        XCTAssertEqual(
            JourneyCoverageDisclosure(coverage: JourneyCoverage(features: states)).kind, .unconfirmed,
            "One unknown feature means the absence of live data is not established"
        )
    }

    func testConnectedSupportWithoutAnObservationDoesNotClaimToBeReporting() {
        let coverage = JourneyCoverage(features: [
            .delays: State(support: .connected), .position: State(support: .connected),
        ])
        let disclosure = JourneyCoverageDisclosure(coverage: coverage)

        XCTAssertEqual(disclosure.kind, .connected)
        XCTAssertEqual(disclosure.title, "Live delays · Train location")
        XCTAssertNil(disclosure.detail)
        XCTAssertFalse(disclosure.isGap)
    }

    func testAFreshObservationEstablishesTheFeatureForThisTrainOnly() {
        let coverage = JourneyCoverage(
            features: [.position: State(support: .unknown, availability: .observed, observedAt: .now)],
            scopeName: "PID regional rail",
            limitationCodes: ["regionalScope"]
        )
        let disclosure = JourneyCoverageDisclosure(coverage: coverage)

        XCTAssertEqual(disclosure.kind, .limited)
        XCTAssertEqual(disclosure.title, "Train location")
        XCTAssertEqual(
            disclosure.detail,
            "Live delays not confirmed. Covers PID regional rail only."
        )
    }

    func testAnUndatedLocationIsNotAnObservedPointButUndatedDelaysStillCount() throws {
        let undated = try decode(#"""
        {"schemaVersion":1,"features":{
          "position":{"support":"unknown","availability":"observed","observedAt":null},
          "delays":{"support":"unknown","availability":"observed","observedAt":null}}}
        """#)
        XCTAssertEqual(undated.established, [.delays], "Delays carry no publisher clock; a location must")

        let malformed = try decode(#"""
        {"schemaVersion":1,"features":{"position":{"support":"unknown","availability":"observed","observedAt":"soon"}}}
        """#)
        XCTAssertTrue(malformed.established.isEmpty)
        XCTAssertEqual(JourneyCoverageDisclosure(coverage: malformed).kind, .unconfirmed)

        let connectedButUndated = try decode(#"""
        {"schemaVersion":1,"features":{"position":{"support":"connected","availability":"observed","observedAt":null}}}
        """#)
        XCTAssertEqual(connectedButUndated.established, [.position], "Durable support is a separate fact")
    }

    func testNoRowClaimsTheTrainIsReportingRightNow() {
        let everything = JourneyCoverage(features: Dictionary(uniqueKeysWithValues: Feature.allCases.map {
            ($0, State(support: .connected, availability: .observed, observedAt: .now))
        }))
        let disclosure = JourneyCoverageDisclosure(coverage: everything)
        XCTAssertEqual(disclosure.title, "Live delays · Cancellations · Platforms · Train location")
        XCTAssertNil(disclosure.detail, "Capability text carries no freshness promise")
    }

    func testNoLocationAndNoDelaysAreDifferentGaps() {
        let noLocation = JourneyCoverageDisclosure(coverage: JourneyCoverage(features: [
            .delays: State(support: .connected), .cancellations: State(support: .connected),
            .position: State(support: .notProvided),
        ]))
        XCTAssertEqual(noLocation.kind, .limited)
        XCTAssertEqual(noLocation.title, "Live delays · Cancellations")
        XCTAssertEqual(noLocation.detail, "No train location from this source.")

        let noDelays = JourneyCoverageDisclosure(coverage: JourneyCoverage(features: [
            .delays: State(support: .notProvided), .position: State(support: .connected),
        ]))
        XCTAssertEqual(noDelays.title, "Train location")
        XCTAssertEqual(noDelays.detail, "No live delays from this source.")
    }

    func testOnlyADiagnosedFailureIsAnOutage() {
        XCTAssertEqual(JourneyCoverageDisclosure(coverage: .unavailable).kind, .unavailableNow)

        let quiet = JourneyCoverage(features: [.delays: State(support: .connected, availability: .notObserved)])
        XCTAssertNotEqual(JourneyCoverageDisclosure(coverage: quiet).kind, .unavailableNow)

        var partial = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, State(availability: .unavailable)) })
        partial[.delays] = State(support: .connected, availability: .observed)
        XCTAssertEqual(JourneyCoverageDisclosure(coverage: JourneyCoverage(features: partial)).kind, .limited)
    }

    // MARK: Summary above Save

    @MainActor
    func testFullyConnectedJourneyShowsNoNoticeAndKeepsTrackWording() {
        let summary = summary(coverages: [Self.connected, Self.connected])
        XCTAssertNil(summary.coverage.notice)
        XCTAssertEqual(summary.statusTitle, "All selected trains are ready to track")
        XCTAssertEqual(summary.primaryActionTitle, "Track Journey")
        XCTAssertTrue(summary.canTrack)
    }

    @MainActor
    func testLegacyResponseWithoutCoverageStaysSaveableAndSaysNotConfirmed() {
        let summary = summary(coverages: [.unconfirmed])
        XCTAssertEqual(summary.coverage.notice?.title, "Live coverage not confirmed")
        XCTAssertEqual(summary.coverage.notice?.isOutage, false)
        XCTAssertEqual(summary.statusTitle, "Ready to save")
        XCTAssertEqual(summary.primaryActionTitle, "Track Journey")
        XCTAssertTrue(summary.canTrack)
    }

    @MainActor
    func testScheduleOnlyPlanSavesInsteadOfTracks() {
        let oneWay = summary(coverages: [Self.scheduleOnly])
        XCTAssertEqual(oneWay.coverage.notice?.title, "Schedule only")
        XCTAssertEqual(oneWay.primaryActionTitle, "Save Journey")
        XCTAssertTrue(oneWay.canTrack)

        let roundTrip = summary(coverages: [Self.scheduleOnly, Self.scheduleOnly], isRoundTrip: true)
        XCTAssertEqual(roundTrip.primaryActionTitle, "Save Round Trip")
    }

    @MainActor
    func testOneCoveredLegCannotMakeAMixedJourneyLookLive() {
        let summary = summary(coverages: [Self.connected, Self.scheduleOnly])
        XCTAssertEqual(summary.coverage.notice?.title, "Live coverage varies by train")
        XCTAssertEqual(
            summary.coverage.notice?.message,
            "1 of 2 trains has limited or unconfirmed live updates. Each train shows what it provides."
        )
        XCTAssertEqual(summary.statusTitle, "Ready to save")
        XCTAssertEqual(summary.primaryActionTitle, "Track Journey", "A connected leg is still tracked")
        XCTAssertEqual(summary.coverage.trains.map(\.kind), [.connected, .scheduleOnly])
    }

    @MainActor
    func testSingleLimitedTrainLetsItsOwnRowSpeak() {
        let limited = JourneyCoverage(features: [
            .delays: State(support: .connected), .position: State(support: .notProvided),
        ])
        XCTAssertNil(summary(coverages: [limited]).coverage.notice)
        XCTAssertNotNil(summary(coverages: [limited, Self.connected]).coverage.notice)
    }

    @MainActor
    func testOutageNoticeIsAWarningAndStillAllowsSaving() {
        let summary = summary(coverages: [.unavailable])
        XCTAssertEqual(summary.coverage.notice?.title, "Updates unavailable right now")
        XCTAssertEqual(summary.coverage.notice?.isOutage, true)
        XCTAssertTrue(summary.canTrack)
    }

    // MARK: Store: saving and checking again

    @MainActor
    func testScheduleOnlyAndUnknownCoverageBothSave() async {
        for coverage in [Self.scheduleOnly, JourneyCoverage.unconfirmed] {
            let outbound = journeyOutboundOption()
            let resolution = Self.resolution(outbound: outbound, coverages: [coverage])
            let client = ScriptedJourneySearchClient(
                pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
                resolutions: [.success(resolution)]
            )
            let tracker = RecordingJourneyPlanTracker()
            let store = await prepareOneWayJourneyReview(client: client, tracker: tracker, outbound: outbound)
            store.resolveSelection()
            await waitUntil { store.canTrackAvailableTrips }

            XCTAssertNotNil(store.resolutionSummary?.coverage.notice)
            XCTAssertTrue(store.trackResolvedPlan())
            XCTAssertEqual(tracker.calls.count, 1)
            XCTAssertEqual(tracker.calls.first?.resolution, resolution)
        }
    }

    @MainActor
    func testCheckingAgainKeepsTheSelectionAndReplacesAnOutageWithFreshCoverage() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [
                .success(Self.resolution(outbound: outbound, coverages: [.unavailable])),
                .success(Self.resolution(outbound: outbound, coverages: [Self.connected])),
            ]
        )
        let tracker = RecordingJourneyPlanTracker()
        let store = await prepareOneWayJourneyReview(client: client, tracker: tracker, outbound: outbound)
        store.resolveSelection()
        await waitUntil { store.canTrackAvailableTrips }
        XCTAssertEqual(store.resolutionSummary?.coverage.notice?.isOutage, true)

        store.resolveSelection()
        await waitUntil { store.resolutionSummary?.coverage.notice == nil && store.canTrackAvailableTrips }

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertTrue(tracker.calls.isEmpty, "Checking coverage never saves")
        XCTAssertTrue(store.trackResolvedPlan())
    }

    @MainActor
    func testImportedTicketAutoSelectionStopsAtTheDisclosureBeforeAnythingIsSaved() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(
            places: [.success([JourneySearchStoreFixtures.paris]), .success([JourneySearchStoreFixtures.amsterdam])],
            pages: [.success(JourneySearchStoreFixtures.page(options: [outbound]))],
            resolutions: [.success(Self.resolution(outbound: outbound, coverages: [Self.scheduleOnly]))]
        )
        let tracker = RecordingJourneyPlanTracker()
        let store = makeJourneySearchStore(client: client, tracker: tracker, form: JourneySearchFormState())

        await store.prefillTicketJourney(TicketJourneySearchRequest(
            originName: "Paris", destinationName: "Amsterdam", departureTime: "2026-07-24T06:25:00Z",
            trainNumber: "9315", calendarSource: nil, prefersDirectReview: true
        ))
        await waitUntil { store.phase == .reviewing }
        XCTAssertNil(store.resolutionSummary, "Review opens before any coverage claim exists")
        XCTAssertTrue(tracker.calls.isEmpty)

        store.resolveSelection()
        await waitUntil { store.canTrackAvailableTrips }

        XCTAssertEqual(store.phase, .reviewing)
        XCTAssertEqual(store.resolutionSummary?.coverage.notice?.title, "Schedule only")
        XCTAssertEqual(store.resolutionSummary?.primaryActionTitle, "Save Journey")
        XCTAssertTrue(tracker.calls.isEmpty, "Only the traveller's tap saves")
    }

    // MARK: Fixtures

    private static let connected = JourneyCoverage(features: [
        .delays: State(support: .connected), .position: State(support: .connected),
    ])

    private static let scheduleOnly = JourneyCoverage(features: Dictionary(
        uniqueKeysWithValues: Feature.allCases.map { ($0, State(support: .notProvided)) }
    ))

    @MainActor
    private static func resolution(outbound: JourneyOption, coverages: [JourneyCoverage]) -> JourneyPlanResolution {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let base = JourneySearchStoreFixtures.resolution(
            outbound: outbound,
            outboundTrips: Array(trips.prefix(coverages.count))
        )
        return JourneyPlanResolution(directions: base.directions.map { direction in
            JourneyPlanResolution.Direction(
                fingerprint: direction.fingerprint,
                originStationID: direction.originStationID,
                destinationStationID: direction.destinationStationID,
                departure: direction.departure,
                arrival: direction.arrival,
                segments: zip(direction.segments, coverages).map { segment, coverage in
                    JourneyPlanResolution.Segment(
                        segmentID: segment.segmentID, trip: segment.trip, failure: nil, coverage: coverage
                    )
                }
            )
        })
    }

    @MainActor
    private func summary(coverages: [JourneyCoverage], isRoundTrip: Bool = false) -> JourneyResolutionSummary {
        JourneyResolutionSummary(
            resolution: Self.resolution(outbound: journeyOutboundOption(), coverages: coverages),
            isRoundTrip: isRoundTrip,
            availableSubsetConfirmed: false
        )
    }

    private func decode(_ json: String) throws -> JourneyCoverage {
        try JSONDecoder().decode(JourneyCoverage.self, from: Data(json.utf8))
    }

    private static let contractExample = #"""
    {"schemaVersion":1,"assessedAt":"2026-11-13T22:50:00.000Z","reviewedAt":"2026-11-13",
     "scopeName":"PID regional rail","countryCodes":["CZ"],"sourceIds":["golemio-pid"],
     "features":{
       "delays":{"support":"unknown","availability":"notObserved","observedAt":null},
       "cancellations":{"support":"unknown","availability":"notObserved","observedAt":null},
       "platforms":{"support":"unknown","availability":"notObserved","observedAt":null},
       "position":{"support":"connected","availability":"observed","observedAt":"2026-11-13T22:49:45.000Z"}
     },
     "limitationCodes":["regionalScope","exactServiceRequired"],
     "detailsURL":"https://gettraintracker.com/coverage"}
    """#
}
