import AppIntents

@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchTrainTrackerIntent {
    static let title: LocalizedStringResource = "Search Roundhouse"
    static let description = IntentDescription("Open Roundhouse and search for a station.")
    static let searchScopes: [StringSearchScope] = [.general]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var supportedModes: IntentModes { .foreground }

    var criteria: StringSearchCriteria

    init() {
        criteria = StringSearchCriteria(term: "")
    }

    init(criteria: StringSearchCriteria) {
        self.criteria = criteria
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        TrainJourneyRuntime.shared.navigation.openStationSearch(query: criteria.term)
        return .result()
    }
}
