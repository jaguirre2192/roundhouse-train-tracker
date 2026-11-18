import AppIntents

struct OpenSavedTrainIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Saved Train"
    static let description = IntentDescription("Open the journey for a train saved in Roundhouse.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Train")
    var target: SavedTrainEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    init() {}

    init(target: SavedTrainEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try TrainJourneyRuntime.shared.openSavedTrain(id: target.id)
        return .result()
    }
}
