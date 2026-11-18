import AppIntents

struct StopTrainLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Train Live Activity"
    static let description = IntentDescription("Remove the current train Live Activity from the Lock Screen and Dynamic Island.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        await TrainLiveActivityManager.shared.stop()
        return .result()
    }
}
