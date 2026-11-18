import Foundation
import Observation
import TrainTrackerCore

/// Which changes to a tracked train send a notification. The alert service applies these per
/// train, so a change reaches trains already tracked the next time their alerts are refreshed.
enum AlertPreference {
    static let delayThreshold = "preference.alerts.delayThresholdMinutes"
    static let platformChanges = "preference.alerts.platformChanges"
    static let cancellations = "preference.alerts.cancellations"
    static let disruptions = "preference.alerts.disruptions"

    static let delayThresholdChoices = [5, 10, 15, 30]

    static func stored(in defaults: UserDefaults = .standard) -> PushPreferences {
        let threshold = defaults.object(forKey: delayThreshold) as? Int ?? 5
        return PushPreferences(
            delayThresholdMinutes: delayThresholdChoices.contains(threshold) ? threshold : 5,
            notifiesPlatformChanges: defaults.object(forKey: platformChanges) as? Bool ?? true,
            notifiesCancellations: defaults.object(forKey: cancellations) as? Bool ?? true,
            notifiesDisruptions: defaults.object(forKey: disruptions) as? Bool ?? true
        )
    }
}

/// The station or city journey search starts from when the form is empty.
@MainActor
@Observable
final class HomeStationStore {
    static let standard = HomeStationStore(defaults: .standard)

    private(set) var place: RailPlace?

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String = "preference.homeStation") {
        self.defaults = defaults
        self.key = key
        place = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(RailPlace.self, from: $0) }
    }

    func set(_ place: RailPlace) {
        self.place = place
        if let data = try? JSONEncoder().encode(place) { defaults.set(data, forKey: key) }
    }

    func clear() {
        place = nil
        defaults.removeObject(forKey: key)
    }
}
