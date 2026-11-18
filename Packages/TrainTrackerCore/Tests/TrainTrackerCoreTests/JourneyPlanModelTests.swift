import Foundation
import Testing
@testable import TrainTrackerCore

@Suite("JourneyPlanModelTests")
struct JourneyPlanModelTests {
    @Test func planDraftIdentityAndDirectionSummaryPreserveSelectedJourney() {
        let planID = UUID(uuidString: "A1D3F696-676D-4A34-9D43-6A79E5D0359A")!
        let origin = planPlace(id: "origin")
        let destination = planPlace(id: "destination")
        let option = planOption()
        let childID = RailIdentifier(rawValue: "eu:fixture:train-1")
        let draft = JourneyPlanDraft(
            id: planID,
            origin: origin,
            destination: destination,
            outbound: option,
            returnOption: nil
        )
        let direction = JourneyPlanDirection(
            fingerprint: option.fingerprint,
            departure: option.startTime,
            arrival: option.endTime,
            childTripIDs: [childID]
        )

        #expect(draft.id == planID)
        #expect(draft.origin.id == origin.id)
        #expect(draft.destination.id == destination.id)
        #expect(draft.outbound.id == option.id)
        #expect(draft.returnOption == nil)
        #expect(direction.fingerprint == option.fingerprint)
        #expect(direction.departure == option.startTime)
        #expect(direction.arrival == option.endTime)
        #expect(direction.childTripIDs == [childID])
        requirePlanSendable(draft)
    }

    @Test func trackedPlanRoundTripsWithPreExistingChildren() throws {
        let planID = UUID(uuidString: "A1D3F696-676D-4A34-9D43-6A79E5D0359A")!
        let childID = RailIdentifier(rawValue: "eu:fixture:train-1")
        let direction = JourneyPlanDirection(
            fingerprint: "fingerprint-1",
            departure: Date(timeIntervalSince1970: 1_800_100_000),
            arrival: Date(timeIntervalSince1970: 1_800_107_200),
            childTripIDs: [childID]
        )
        let plan = TrackedJourneyPlan(
            id: planID,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            origin: planPlace(id: "origin"),
            destination: planPlace(id: "destination"),
            outbound: direction,
            returnDirection: nil,
            preExistingChildTripIDs: [childID]
        )

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(TrackedJourneyPlan.self, from: data)

        #expect(decoded == plan)
        #expect(decoded.id == planID)
        #expect(decoded.preExistingChildTripIDs == [childID])
        #expect(Set([plan]).count == 1)
        requirePlanSendable(plan)
    }
}

private func planOption() -> JourneyOption {
    JourneyOption(
        id: "option-1",
        fingerprint: "fingerprint-1",
        startTime: Date(timeIntervalSince1970: 1_800_100_000),
        endTime: Date(timeIntervalSince1970: 1_800_107_200),
        duration: 7_200,
        transferCount: 0,
        segments: [],
        badges: [.direct],
        trackability: JourneyTrackability(trackableRailSegments: 1, totalRailSegments: 1),
        realtimeFreshness: nil,
        attributions: ["Fixture Rail"],
        trackingToken: "tracking-token"
    )
}

private func planPlace(id: String) -> RailPlace {
    RailPlace(
        id: RailIdentifier(rawValue: "eu:fixture:\(id)"),
        kind: .station,
        displayName: id.capitalized,
        context: "Fixtureland",
        countryCode: "FX",
        timeZoneIdentifier: "Europe/Paris",
        location: GeoCoordinate(latitude: 48.8, longitude: 2.3),
        eligibleModes: ["longDistanceRail"],
        attributions: ["Fixture Rail"]
    )
}

private func requirePlanSendable<T: Sendable>(_ value: T) {}
