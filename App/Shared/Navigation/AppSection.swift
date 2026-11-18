import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case trips
    case stations
    case map
    case settings

    var id: Self { self }

    /// There is no tab bar. My Trips is the root; the other sections remain as the names
    /// screens, Siri and links use to ask for search, a trip's map or Settings.
    static let tabs: [AppSection] = [.trips]

    var title: String {
        switch self {
        case .trips: "My Trips"
        case .stations: "Search"
        case .map: "Map"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .trips: "train.side.front.car"
        case .stations: "magnifyingglass"
        case .map: "map"
        case .settings: "gearshape"
        }
    }
}
