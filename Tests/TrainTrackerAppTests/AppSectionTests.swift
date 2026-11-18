import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class AppSectionTests: XCTestCase {
    func testRetiredGmailImportIsDisabledInEveryBuild() {
        XCTAssertFalse(ReleaseFeatures.gmailImportEnabled)
    }

    func testSearchSectionKeepsStoredNavigationIdentity() {
        XCTAssertEqual(AppSection.stations.rawValue, "stations")
    }

    func testEverySectionHasVisibleNavigationMetadata() {
        for section in AppSection.allCases {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.systemImage.isEmpty)
        }
    }

    func testStationSearchKeepsResultsWhilePresentingABoard() {
        XCTAssertFalse(
            StationSearchResultPolicy.shouldClearResults(
                query: "",
                didSearch: true,
                isPresentingBoard: true
            )
        )
        XCTAssertTrue(
            StationSearchResultPolicy.shouldClearResults(
                query: "",
                didSearch: true,
                isPresentingBoard: false
            )
        )
    }

    func testJourneyDataSourcesAreReachableAndQualifiedWithoutUniversalClaims() {
        XCTAssertEqual(
            JourneyDataSources.settings.map(\.title),
            [
                "Transitous",
                "OpenStreetMap",
                "Operator and feed coverage",
                "VIA Rail GTFS — Open Government Licence Canada 2.0",
                "Amtrak route lines — U.S. DOT National Transportation Atlas Database",
            ]
        )
        for source in JourneyDataSources.settings {
            XCTAssertEqual(source.destination.scheme, "https")
            XCTAssertNotNil(source.destination.host)
        }
        XCTAssertTrue(JourneyDataSources.qualification.localizedCaseInsensitiveContains("varies"))
        XCTAssertTrue(JourneyDataSources.qualification.localizedCaseInsensitiveContains("operator"))
        XCTAssertFalse(JourneyDataSources.qualification.localizedCaseInsensitiveContains("every operator"))
    }

    @MainActor
    func testTripArchiveRoundTripsTrackedTrips() throws {
        let suiteName = "TrainTrackerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archive = TripArchive(defaults: defaults)
        let trips = PreviewTrips.make(referenceDate: Date(timeIntervalSince1970: 1_700_000_000))

        archive.save(trips)

        XCTAssertEqual(archive.load(), trips)
    }

    func testTripPresentationStatusMapsToBrandStates() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let trips = PreviewTrips.make(referenceDate: referenceDate)
        let delayedTrip = try XCTUnwrap(trips.first)
        let onTimeTrip = try XCTUnwrap(trips.last)
        let cancelledTrip = trip(delayedTrip, isCancelled: true, isPassed: false)
        let arrivedTrip = trip(delayedTrip, isCancelled: false, isPassed: true)

        let delayed = TripPresentationStatus(trip: delayedTrip, referenceDate: referenceDate)
        XCTAssertEqual(delayed.kind, .delayed)
        XCTAssertEqual(delayed.badgeText, "7 min late")
        XCTAssertEqual(delayed.text, "7 min late")
        XCTAssertEqual(delayed.spokenText, "7 minutes late")
        XCTAssertEqual(LiveLineTicketPresentation.badgeText(for: delayed), "7 min late")
        XCTAssertEqual(LiveLineTicketPresentation.badgeText(for: delayed, isConfirmed: false), "7 min late · Saved",
                       "A delay from saved data never reads like a fresh check")
        let cancelled = TripPresentationStatus(trip: cancelledTrip, referenceDate: referenceDate)
        XCTAssertEqual(LiveLineTicketPresentation.badgeText(for: cancelled, isConfirmed: false), "Canceled")

        XCTAssertEqual(TripPresentationStatus(trip: onTimeTrip, referenceDate: referenceDate).kind, .onTime)
        XCTAssertEqual(TripPresentationStatus(trip: cancelledTrip, referenceDate: referenceDate).kind, .cancelled)
        XCTAssertEqual(TripPresentationStatus(trip: arrivedTrip, referenceDate: referenceDate).kind, .delayed,
                       "Premature passage flags do not end the timetable")
        XCTAssertEqual(TripPresentationStatus(trip: arrivedTrip, referenceDate: referenceDate.addingTimeInterval(3_600 * 2)).kind, .arrived)
    }

    private func trip(
        _ trip: TrainTrip,
        isCancelled: Bool,
        isPassed: Bool
    ) -> TrainTrip {
        let stops = trip.stopTimes.map { stop in
            StopTime(
                station: stop.station,
                sequence: stop.sequence,
                scheduledArrival: stop.scheduledArrival,
                scheduledDeparture: stop.scheduledDeparture,
                expectedArrival: stop.expectedArrival,
                expectedDeparture: stop.expectedDeparture,
                plannedPlatform: stop.plannedPlatform,
                expectedPlatform: stop.expectedPlatform,
                isCancelled: isCancelled,
                isPassed: isPassed
            )
        }

        return TrainTrip(
            id: trip.id,
            source: trip.source,
            serviceDate: trip.serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: stops,
            positions: trip.positions,
            alerts: trip.alerts,
            capabilities: trip.capabilities
        )
    }
}
