import Foundation
import TrainTrackerCore

/// The app scene and system intents share one set of production stores.
@MainActor
final class TrainJourneyRuntime {
    static let shared = TrainJourneyRuntime()

    private(set) lazy var pushCoordinator = PushRegistrationCoordinator()
    private(set) lazy var library = TripLibrary(pushCoordinator: pushCoordinator)
    private(set) lazy var planLibrary = try? JourneyPlanLibrary(tripLibrary: library)
    let navigation: AppNavigationModel

    private init() {
        navigation = AppNavigationModel()
    }

    /// Explicit stores keep route tests independent of the production archives.
    init(library: TripLibrary, planLibrary: JourneyPlanLibrary? = nil, navigation: AppNavigationModel) {
        self.navigation = navigation
        self.library = library
        self.planLibrary = planLibrary
    }

    /// Background intents can reuse stores first opened before protected data was available.
    /// Retry at each read entry, even when the app's scene has never appeared.
    func retryArchiveAvailability() {
        try? library.retryTripArchiveRecovery()
        try? planLibrary?.retryRecovery()
    }

    func ensureActivityConnection() {
        retryArchiveAvailability()
        TrainLiveActivityManager.shared.connect(library: library, plans: planLibrary)
        WidgetSnapshotPublisher.shared.connect(library: library, plans: planLibrary)
    }

    func openSavedTrain(id: String) throws {
        retryArchiveAvailability()
        let tripID = RailIdentifier(rawValue: id)
        guard library.containsTrip(id: tripID) else { throw SavedTrainIntentError.missingTrain }
        navigation.openJourney(tripID: tripID)
    }
}

enum SavedTrainIntentError: LocalizedError {
    case missingTrain

    var errorDescription: String? {
        "This train is no longer saved. Open Roundhouse to choose another train."
    }
}
