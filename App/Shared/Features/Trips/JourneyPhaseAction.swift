import SwiftUI
import TrainTrackerCore

/// The one action that matters most for a train right now. It follows the timetable phase and
/// what the app can actually do: start a Live Activity while one can start, the boarding
/// station's map before departure, the live map once underway, a new search after cancellation.
enum JourneyPhaseAction: Equatable {
    case showOnLockScreen
    case stationMap(URL)
    case liveMap
    case findAnotherTrain
    case viewJourney

    static func resolve(
        trip: TrainTrip, progress: RailJourneyProgress, canStartLiveActivity: Bool, stationMapURL: URL?
    ) -> JourneyPhaseAction {
        if trip.isCancelled || progress.isCancelled { return .findAnotherTrain }
        switch progress.phase {
        case .ended, .unavailable:
            return .viewJourney
        case .underway:
            return canStartLiveActivity ? .showOnLockScreen : .liveMap
        case .upcoming, .departureSoon:
            if canStartLiveActivity { return .showOnLockScreen }
            return stationMapURL.map(JourneyPhaseAction.stationMap) ?? .viewJourney
        }
    }

    var title: String {
        switch self {
        case .showOnLockScreen: "Show on Lock Screen"
        case .stationMap: "Station Map"
        case .liveMap: "Open Live Map"
        case .findAnotherTrain: "Find Another Train"
        case .viewJourney: "View Journey"
        }
    }

    var systemImage: String {
        switch self {
        case .showOnLockScreen: "platter.filled.bottom.iphone"
        case .stationMap: "map"
        case .liveMap: "location.viewfinder"
        case .findAnotherTrain: "magnifyingglass"
        case .viewJourney: "arrow.right"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .showOnLockScreen: "Follows this train on your Lock Screen"
        case .stationMap: "Opens this station in Maps"
        case .liveMap: "Shows this train on the map"
        case .findAnotherTrain: "Opens train search"
        case .viewJourney: "Opens this train's details"
        }
    }
}

/// A full-width primary button whose label and symbol change with the journey.
struct JourneyPhaseActionButton: View {
    let action: JourneyPhaseAction
    var isBusy = false
    let perform: (JourneyPhaseAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { perform(action) } label: {
            Label {
                Text(action.title)
                    .contentTransition(.interpolate)
            } icon: {
                Image(systemName: action.systemImage)
                    .contentTransition(.symbolEffect(.replace))
            }
            // The large control size already clears the 44 pt target; a taller label makes a slab.
            .frame(maxWidth: .infinity)
        }
        .trainTrackerPrimaryAction()
        .controlSize(.large)
        .disabled(isBusy)
        .animation(reduceMotion ? nil : .snappy, value: action)
        .accessibilityHint(action.accessibilityHint)
        .accessibilityIdentifier("journeyPhaseAction")
    }
}
