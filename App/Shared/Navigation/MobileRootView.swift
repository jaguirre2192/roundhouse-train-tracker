import SwiftUI
import UIKit

/// The app's root on every width. There is no tab bar: My Trips is home, and search, Settings
/// and each trip's map-backed screen open from it.
struct MobileRootView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var tripsZoom

    var body: some View {
        sectionRoot(.trips)
            .tint(Color.ttActionTint)
            .onChange(of: navigation.requestedSection, initial: true) { _, requestedSection in
                guard requestedSection != nil,
                      let section = navigation.consumeRequestedSection() else { return }
                switch section {
                case .trips:
                    break
                case .stations:
                    if navigation.tripsPath != [.search] { navigation.tripsPath = [.search] }
                case .settings:
                    if navigation.tripsPath != [.settings] { navigation.tripsPath = [.settings] }
                case .map:
                    // The map lives behind each trip's details now.
                    if let trip = library.activeTrip ?? library.trips.first {
                        navigation.tripsPath = [.train(trip.id)]
                    }
                }
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-AppStorePreviewStations") {
                    navigation.open(AppSection.stations)
                } else if arguments.contains("-AppStorePreviewSettings") {
                    navigation.open(AppSection.settings)
                } else if arguments.contains("-AppStorePreviewMap") || arguments.contains("-AmtrakPositionQA") {
                    navigation.open(AppSection.map)
                }
            }
    }
}

extension MobileRootView {
    /// Phones keep the same map-led navigation stack when they unfold or rotate. A regular
    /// iPad can still show its journey library beside the selected train.
    @ViewBuilder
    fileprivate func sectionRoot(_ section: AppSection) -> some View {
        if section == .trips, horizontalSizeClass == .regular, UIDevice.current.userInterfaceIdiom != .phone {
            MyTripsSplitView()
        } else if section == .trips {
            // The stack and its map remain the same view on both phone displays. The shared
            // path also preserves the selected destination when an iPad changes column layout.
            @Bindable var navigation = navigation
            NavigationStack(path: $navigation.tripsPath) {
                AppSectionContent(section: section, isSelected: true)
                    .navigationDestination(for: TripsRoute.self) {
                        TripsRouteDestination(route: $0).tripsZoomDestination($0)
                    }
            }
            .environment(\.tripsZoomNamespace, tripsZoom)
        } else {
            NavigationStack {
                AppSectionContent(section: section, isSelected: true)
            }
        }
    }
}
