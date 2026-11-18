import AppIntents
import CoreSpotlight

struct SavedTrainQuery: EntityStringQuery {
    private let snapshot: @MainActor @Sendable () -> SavedTrainEntityCatalog

    init() {
        snapshot = {
            let runtime = TrainJourneyRuntime.shared
            runtime.retryArchiveAvailability()
            return SavedTrainEntityCatalog(
                trips: runtime.library.trips, plans: runtime.planLibrary?.plans ?? []
            )
        }
    }

    init(snapshot: @escaping @MainActor @Sendable () -> SavedTrainEntityCatalog) {
        self.snapshot = snapshot
    }

    func entities(for identifiers: [SavedTrainEntity.ID]) async throws -> [SavedTrainEntity] {
        await snapshot().entities(for: identifiers)
    }

    func entities(matching string: String) async throws -> [SavedTrainEntity] {
        await snapshot().entities(matching: string)
    }

    func suggestedEntities() async throws -> [SavedTrainEntity] {
        await snapshot().suggestedEntities()
    }
}

struct SavedTrainOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [SavedTrainEntity] {
        try await SavedTrainQuery().suggestedEntities()
    }
}

@available(iOS 27.0, *)
extension SavedTrainQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [SavedTrainEntity.ID],
        indexDescription _: CSSearchableIndexDescription
    ) async throws {
        let entities = await snapshot().entities(for: identifiers)
        try await SavedTrainSpotlightIndexer.reindex(entities)
    }

    func reindexAllEntities(indexDescription _: CSSearchableIndexDescription) async throws {
        let entities = await snapshot().allEntities()
        try await SavedTrainSpotlightIndexer.reindex(entities)
    }
}
