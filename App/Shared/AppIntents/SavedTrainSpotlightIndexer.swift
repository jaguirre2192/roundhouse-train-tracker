import CoreSpotlight
import Foundation
import OSLog

struct SavedTrainSpotlightUpdate: Equatable {
    let entities: [SavedTrainEntity]
    let removedIdentifiers: [String]

    init(entities: [SavedTrainEntity], previouslyIndexedIdentifiers: [String]) {
        self.entities = entities
        let currentIdentifiers = Set(entities.map(\.id))
        removedIdentifiers = Set(previouslyIndexedIdentifiers)
            .subtracting(currentIdentifiers)
            .sorted()
    }
}

enum SavedTrainSpotlightIndexer {
    private static let indexName = "SavedTrains"
    private static let indexedIdentifiersKey = "SavedTrainSpotlightIndexer.indexedIdentifiers"
    private static let logger = Logger(
        subsystem: "com.jorgeaguirre.TrainTracker",
        category: "saved-train-index"
    )

    static func synchronize(
        _ entities: [SavedTrainEntity],
        defaults: UserDefaults = .standard
    ) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let update = SavedTrainSpotlightUpdate(
            entities: entities,
            previouslyIndexedIdentifiers: defaults.stringArray(forKey: indexedIdentifiersKey) ?? []
        )
        let index = CSSearchableIndex(name: indexName)

        do {
            if !update.removedIdentifiers.isEmpty {
                try await index.deleteAppEntities(
                    identifiedBy: update.removedIdentifiers,
                    ofType: SavedTrainEntity.self
                )
            }
            if !update.entities.isEmpty {
                try await index.indexAppEntities(update.entities)
            }
            defaults.set(update.entities.map(\.id).sorted(), forKey: indexedIdentifiersKey)
        } catch {
            logger.error("Saved-train Spotlight synchronization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func reindex(_ entities: [SavedTrainEntity]) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        try await CSSearchableIndex(name: indexName).indexAppEntities(entities)
    }
}
