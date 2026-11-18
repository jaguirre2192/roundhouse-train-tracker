import AppIntents
import TrainTrackerCore

struct StartTrainLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Train Live Activity"
    static let description = IntentDescription("Follow a saved train on the Lock Screen and Dynamic Island.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Train")
    var train: SavedTrainEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start a Live Activity for \(\.$train)")
    }

    init() {}

    init(train: SavedTrainEntity) {
        self.train = train
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let runtime = TrainJourneyRuntime.shared
        runtime.ensureActivityConnection()
        try await TrainLiveActivityManager.shared.start(tripID: RailIdentifier(rawValue: train.id))
        return .result()
    }
}
