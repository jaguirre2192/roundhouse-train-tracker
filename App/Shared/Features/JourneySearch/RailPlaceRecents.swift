import Foundation
import Observation
import TrainTrackerCore

@MainActor
@Observable
final class RailPlaceRecents {
    static let standard = RailPlaceRecents(defaults: LaunchFixtures.isActive ? nil : .standard)

    private(set) var places: [RailPlace]
    private(set) var routes: [RecentRailRoute]
    var count: Int { places.count + routes.count }

    private let defaults: UserDefaults?
    private let key: String
    private var routeKey: String { key + ".routes" }

    init(defaults: UserDefaults?, key: String = "recentRailPlaces") {
        self.defaults = defaults
        self.key = key
        places = Self.load(RailPlace.self, from: defaults, key: key)
        routes = Self.load(RecentRailRoute.self, from: defaults, key: key + ".routes") {
            $0.origin.id != $0.destination.id
        }
    }

    func record(_ place: RailPlace) {
        places = Self.normalized([place] + places)
        Self.save(places, to: defaults, key: key)
    }

    /// Only an explicit Search Trains action supplies a pair. Individual station picks
    /// also come from settings and abandoned searches and have no reliable direction.
    func recordSearch(_ form: JourneySearchFormState) {
        guard let origin = form.origin, let destination = form.destination, origin.id != destination.id else { return }
        routes = Self.normalized([RecentRailRoute(origin: origin, destination: destination)] + routes)
        Self.save(routes, to: defaults, key: routeKey)
    }

    func choices(for form: JourneySearchFormState) -> (suggested: RecentRailRoute?, alternatives: [RecentRailRoute])? {
        guard !routes.isEmpty, form.origin == nil || form.destination == nil else { return nil }
        let suggested = routes.first { route in
            (form.origin == nil || route.origin.id == form.origin?.id)
                && (form.destination == nil || route.destination.id == form.destination?.id)
        }
        return (suggested, routes.filter { $0.id != suggested?.id })
    }

    func remove(_ route: RecentRailRoute) {
        routes.removeAll { $0.id == route.id }
        Self.save(routes, to: defaults, key: routeKey)
    }

    func clearRoutes() {
        routes = []
        defaults?.removeObject(forKey: routeKey)
    }

    func clearPlaces() {
        places = []
        defaults?.removeObject(forKey: key)
    }

    func clear() {
        clearPlaces()
        clearRoutes()
    }

    private static func load<Item: Codable & Identifiable & Equatable>(
        _ type: Item.Type, from defaults: UserDefaults?, key: String,
        including isValid: (Item) -> Bool = { _ in true }
    ) -> [Item] {
        guard let data = defaults?.data(forKey: key),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        let result = normalized(saved.filter(isValid))
        if result != saved { save(result, to: defaults, key: key) }
        return result
    }

    private static func normalized<Item: Identifiable>(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return Array(items.filter { seen.insert($0.id).inserted }.prefix(6))
    }

    private static func save<Item: Encodable>(_ items: [Item], to defaults: UserDefaults?, key: String) {
        guard let defaults else { return }
        if items.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}

struct RecentRailRoute: Identifiable, Codable, Equatable {
    struct ID: Hashable {
        let origin: RailIdentifier
        let destination: RailIdentifier
    }

    let origin: RailPlace
    let destination: RailPlace

    var id: ID { ID(origin: origin.id, destination: destination.id) }
}
