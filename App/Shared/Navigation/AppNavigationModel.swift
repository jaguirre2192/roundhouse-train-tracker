import Foundation
import Observation
import TrainTrackerCore

struct TicketJourneySearchRequest: Identifiable, Equatable {
    let id: UUID
    let originName: String
    let destinationName: String
    let departureTime: String?
    let trainNumber: String?
    let calendarSource: CalendarJourneySource?
    let prefersDirectReview: Bool
    let originPlace: RailPlace?
    let destinationPlace: RailPlace?

    init(
        id: UUID = UUID(),
        originName: String,
        destinationName: String,
        departureTime: String?,
        trainNumber: String?,
        calendarSource: CalendarJourneySource? = nil,
        prefersDirectReview: Bool = false,
        originPlace: RailPlace? = nil,
        destinationPlace: RailPlace? = nil
    ) {
        self.id = id
        self.originName = originName
        self.destinationName = destinationName
        self.departureTime = departureTime
        self.trainNumber = trainNumber
        self.calendarSource = calendarSource
        self.prefersDirectReview = prefersDirectReview
        self.originPlace = Self.recognizedStation(originPlace, named: originName)
        self.destinationPlace = Self.recognizedStation(destinationPlace, named: destinationName)
    }

    /// A selected ID belongs only to the displayed name it was chosen for.
    static func recognizedStation(_ place: RailPlace?, named name: String) -> RailPlace? {
        guard let place, place.kind == .station,
              place.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        else { return nil }
        return place
    }
}

struct StationSearchRequest: Identifiable, Equatable, Hashable {
    let id: UUID
    let query: String

    init(id: UUID = UUID(), query: String) {
        self.id = id
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class AppNavigationModel {
    private(set) var requestedSection: AppSection?
    private(set) var requestedTicketJourneySearch: TicketJourneySearchRequest?
    private(set) var requestedStationSearch: StationSearchRequest?
    private(set) var requestedJourney: JourneyNavigationRequest?
    private(set) var requestedJourneyPlanID: UUID?
    /// Trips opened from My Trips, outermost first. Held here, above the layout, so folding an
    /// iPhone Duo (stack on the outer display, split view on the inner one) or resizing keeps
    /// the open trip: the stack pushes this path and the split view's detail column shows its
    /// first route. Unfolding with nothing open keeps the default detail and opens nothing.
    var tripsPath: [TripsRoute] = []

    /// Selects a trip from the split view's sidebar, replacing what the detail column shows.
    func open(_ route: TripsRoute) {
        tripsPath = [route]
    }

    func openJourney(tripID: RailIdentifier, boardingStationID: String? = nil, alightingStationID: String? = nil) {
        requestedJourney = JourneyNavigationRequest(
            tripID: tripID, boardingStationID: boardingStationID, alightingStationID: alightingStationID
        )
        requestedSection = .trips
    }

    func dismissJourney() { requestedJourney = nil }

    func openJourneyPlan(id: UUID) {
        requestedJourneyPlanID = id
        requestedSection = .trips
    }

    func dismissJourneyPlan() { requestedJourneyPlanID = nil }

    @discardableResult
    func openJourneyURL(_ url: URL) -> Bool {
        guard let request = JourneyNavigationRequest(url: url) else { return false }
        requestedJourney = request
        requestedSection = .trips
        return true
    }

    func open(_ section: AppSection) {
        requestedSection = section
    }

    func openTicketJourneySearch(_ request: TicketJourneySearchRequest) {
        requestedTicketJourneySearch = request
        requestedSection = .stations
    }

    func openStationSearch(query: String) {
        requestedStationSearch = StationSearchRequest(query: query)
        requestedSection = .stations
    }

    func dismissStationSearch() {
        requestedStationSearch = nil
    }

    @discardableResult
    func consumeRequestedSection() -> AppSection? {
        let section = requestedSection
        requestedSection = nil
        return section
    }


    @discardableResult
    func consumeTicketJourneySearch() -> TicketJourneySearchRequest? {
        let request = requestedTicketJourneySearch
        requestedTicketJourneySearch = nil
        return request
    }

    @discardableResult
    func consumeTicketJourneySearch(ifMatching id: UUID) -> TicketJourneySearchRequest? {
        guard requestedTicketJourneySearch?.id == id else { return nil }
        return consumeTicketJourneySearch()
    }
}
