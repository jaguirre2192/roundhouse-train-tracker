import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class ImportedSavedJourneyMatchTests: XCTestCase {
    private let departure = JourneySearchStoreFixtures.date("2026-11-14T10:00:00Z")
    private let clock = TicketWallClock(year: 2026, month: 11, day: 14, hour: 10, minute: 0)

    func testSpecificBoardingStationDoesNotMatchSavedCityAtAnotherStation() {
        let saved = plan("service", origin: place("london", "London", kind: .city), railFrom: place("liv", "London Liverpool Street"))
        XCTAssertNil(match([saved], number: "123"), "A service number does not excuse a different boarding station")
    }

    func testUnnumberedTicketDoesNotChooseFirstOfTwoServices() {
        let first = plan("first", origin: place("kgx", "London Kings Cross"))
        let second = plan("second", origin: place("kgx", "London Kings Cross"))
        XCTAssertNil(match([first, second]))
        XCTAssertNil(match([second, first]))
    }

    func testResolvedStationIDsMatchPassengerLegInsteadOfSavedCity() {
        let station = place("kgx", "London Kings Cross")
        let saved = plan("service", origin: place("london", "London", kind: .city), railFrom: station)
        XCTAssertEqual(match([saved], originPlace: station, destinationPlace: destination)?.id, saved.id)
    }

    func testConflictingCountryQualifierCannotMatchSavedStation() {
        let saved = plan("service", origin: place("kgx", "London Kings Cross"))
        let found = SmartJourneyReviewStore.existingPlan(
            linkedPlanIDs: [], calendarSource: nil, origin: "London Kings Cross, Canada", destination: "Cambridge",
            trainNumber: "123", departure: clock, knownTimeZone: nil, plans: [saved]
        )
        XCTAssertNil(found)
    }

    func testTrainNumberMustIdentifyTheFirstPassengerTrain() {
        let origin = place("kgx", "London Kings Cross")
        let middle = place("ely", "Ely")
        let segments = [
            JourneyPlanSegment(id: "first", kind: .rail, from: origin, to: middle, serviceName: "Train 111"),
            JourneyPlanSegment(id: "second", kind: .rail, from: middle, to: destination, serviceName: "Train 123")
        ]
        let saved = TrackedJourneyPlan(id: UUID(), createdAt: departure, origin: origin, destination: destination,
            outbound: JourneyPlanDirection(fingerprint: "connecting", departure: departure, arrival: departure.addingTimeInterval(7_200),
                childTripIDs: [], selectedSegments: segments), returnDirection: nil, preExistingChildTripIDs: [])
        XCTAssertNil(match([saved], number: "123"), "A train number on the second leg cannot confirm the first departure")
    }

    private var destination: RailPlace { place("cam", "Cambridge") }

    private func match(_ plans: [TrackedJourneyPlan], number: String = "", originPlace: RailPlace? = nil,
                       destinationPlace: RailPlace? = nil) -> TrackedJourneyPlan? {
        SmartJourneyReviewStore.existingPlan(
            linkedPlanIDs: [], calendarSource: nil, origin: "London Kings Cross", destination: "Cambridge",
            trainNumber: number, departure: clock, knownTimeZone: nil, plans: plans,
            originPlace: originPlace, destinationPlace: destinationPlace
        )
    }

    private func plan(_ fingerprint: String, origin: RailPlace, railFrom: RailPlace? = nil) -> TrackedJourneyPlan {
        let arrival = departure.addingTimeInterval(3_600)
        let segment = JourneyPlanSegment(id: fingerprint, kind: .rail, from: railFrom ?? origin, to: destination,
                                         departure: departure, arrival: arrival, serviceName: "Train 123",
                                         resolvedTripID: RailIdentifier(rawValue: fingerprint))
        return TrackedJourneyPlan(id: UUID(), createdAt: departure, origin: origin, destination: destination,
            outbound: JourneyPlanDirection(fingerprint: fingerprint, departure: departure, arrival: arrival,
                                            childTripIDs: [RailIdentifier(rawValue: fingerprint)], selectedSegments: [segment]),
            returnDirection: nil, preExistingChildTripIDs: [])
    }

    private func place(_ id: String, _ name: String, kind: RailPlace.Kind = .station) -> RailPlace {
        JourneySearchStoreFixtures.place(id: id, name: name, kind: kind, country: "GB", timeZone: "Europe/London")
    }
}
