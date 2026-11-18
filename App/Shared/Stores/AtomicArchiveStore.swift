import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// App-owned archive state. Each mutation reads the latest file and replaces it atomically;
/// MainActor serialization prevents two archive instances from overwriting each other's keys.
@MainActor
struct AtomicArchiveStore {
    enum StorageError: LocalizedError {
        case corruptContainer, protectedDataUnavailable
        var errorDescription: String? {
            switch self {
            case .corruptContainer:
                "Saved train data could not be read. Export or reset it in Settings before making changes."
            case .protectedDataUnavailable:
                "Saved train data is temporarily unavailable. Unlock the device and try again."
            }
        }
    }

    let defaults: UserDefaults
    let fileURL: URL?
    let keys: Set<String>
    var canReadLegacyData: @MainActor () -> Bool = AtomicArchiveStore.protectedDataAvailable

    static func protectedDataAvailable() -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    static func applicationURL(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TrainTrackerArchives", directoryHint: .isDirectory).appending(path: name)
    }

    func values() throws -> [String: Any] {
        guard let fileURL else { return legacyValues() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Preserve legacy data after migration. An existing canonical file is authoritative,
            // including an empty/reset one; unreadable files never fall back to old defaults.
            guard canReadLegacyData() else { throw StorageError.protectedDataUnavailable }
            let legacy = legacyValues()
            try write(legacy, to: fileURL)
            return legacy
        }
        guard let result = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StorageError.corruptContainer
        }
        return result
    }

    func update(_ mutation: (inout [String: Any]) throws -> Void) throws {
        var state = try values()
        try mutation(&state)
        if let fileURL { try write(state, to: fileURL) }
        else {
            // Explicit UserDefaults injection remains available for legacy migration tests.
            for key in keys {
                if let value = state[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
    }

    func preservedPayload(for key: String) throws -> Data {
        if let fileURL {
            do {
                let data = try Data(contentsOf: fileURL)
                guard let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    return data
                }
                if let value = state[key] { return try payload(value) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // A failed migration must leave its legacy source available for export.
                if let value = defaults.object(forKey: key) { return try payload(value) }
            }
        } else if let value = defaults.object(forKey: key) { return try payload(value) }
        throw JourneyPlanRecoveryAccessError.noStoredPayload
    }

    /// An explicit user reset may replace a corrupt container, preserving its original bytes.
    func reset(_ mutation: (inout [String: Any]) -> Void) throws {
        guard let fileURL else { return try update(mutation) }
        var state: [String: Any]
        do { state = try values() }
        catch StorageError.corruptContainer {
            let original = try Data(contentsOf: fileURL)
            let backup = fileURL.appendingPathExtension("recovery-\(UUID().uuidString)")
            try original.write(to: backup, options: Self.writeOptions)
            state = [:]
        }
        mutation(&state)
        try write(state, to: fileURL)
    }

    private func legacyValues() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
    }

    private func payload(_ value: Any) throws -> Data {
        if let data = value as? Data { return data }
        return try PropertyListSerialization.data(fromPropertyList: ["storedValue": value], format: .xml, options: 0)
    }

    private func write(_ state: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        #if os(iOS) || os(watchOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: attributes)
        try data.write(to: url, options: Self.writeOptions)
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }
}
