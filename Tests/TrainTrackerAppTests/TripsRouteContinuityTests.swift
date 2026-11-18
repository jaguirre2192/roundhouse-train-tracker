import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class TripsRouteContinuityTests: XCTestCase {
    func testSelectingInTheSidebarReplacesTheOpenTrip() {
        let navigation = AppNavigationModel()
        let journey = UUID()
        navigation.tripsPath = [.train(RailIdentifier(rawValue: "us:amtraker:171")), .journey(UUID())]

        navigation.open(.journey(journey))

        XCTAssertEqual(navigation.tripsPath, [.journey(journey)])
    }

    func testThePathSurvivesTheLayoutBecauseTheModelOwnsIt() {
        // The compact stack and the split view's detail both read this one path, so a fold that
        // swaps them shows the same trip: the split view's selection is the stack's first push.
        let navigation = AppNavigationModel()
        let train = TripsRoute.train(RailIdentifier(rawValue: "eu:transitous:ice-946"))
        navigation.tripsPath.append(train)
        XCTAssertEqual(navigation.tripsPath.first, train)

        navigation.tripsPath.removeAll()
        XCTAssertNil(navigation.tripsPath.first, "Nothing open means the default detail, never an automatic selection")
    }
}
