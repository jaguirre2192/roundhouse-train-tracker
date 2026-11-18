import Foundation
import XCTest
@testable import TrainTracker

final class CalendarCandidateActionPolicyTests: XCTestCase {
    func testOnlyCompleteTimedCandidatesOfferDirectSearch() {
        XCTAssertTrue(CalendarCandidateActionPolicy.canFindDirectly(candidate()))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(allDay: true)))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(cancelled: true)))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(confidence: .medium)))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(origin: nil)))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(destination: " ")))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(destination: " Boston ")))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(number: nil)))
        XCTAssertFalse(CalendarCandidateActionPolicy.canFindDirectly(candidate(number: " \n")))
    }

    private func candidate(
        allDay: Bool = false, cancelled: Bool = false,
        confidence: TicketRouteConfidence = .high,
        origin: String? = "Boston", destination: String? = "New York", number: String? = "176"
    ) -> CalendarJourneyCandidate {
        CalendarJourneyCandidate(
            snapshot: CalendarEventSnapshot(
                eventIdentifier: "test-event", calendarTitle: "Travel", title: "Amtrak 176",
                notes: nil, location: nil, startDate: .now, endDate: .now.addingTimeInterval(3600),
                isAllDay: allDay, isCancelled: cancelled
            ),
            classification: CalendarJourneyClassification(
                confidence: confidence, evidence: [], originGuess: origin,
                destinationGuess: destination, trainNumberGuess: number
            )
        )
    }
}
