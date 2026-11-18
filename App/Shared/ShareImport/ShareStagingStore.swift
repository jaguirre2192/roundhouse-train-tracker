import Foundation

/// Bounded, file-protected handoff between the Share extension and the host app via the shared
/// App Group container. The extension assembles each item in a hidden staging directory and
/// publishes it with one atomic directory rename. The host leases the bytes without deleting them,
/// then acknowledges the lease only after the person confirms the import or explicitly discards it.
///
/// Every file on disk is untrusted input. Payload paths are derived from a validated UUID, never
/// from an unchecked manifest field. Hidden staging directories are never scanned or purged by the
/// host while fresh, so suspension before the ready-directory rename cannot lose an import that is
/// still inside the same 24-hour lifetime as a published share.
actor ShareStagingStore {
    struct Lease: Sendable {
        fileprivate enum Storage: Sendable, Equatable {
            case readyDirectory
            case legacyFlatFiles
        }

        let manifest: ShareManifest
        let payload: Data
        fileprivate let storage: Storage

        var id: UUID { manifest.id }
    }

    enum StoreError: LocalizedError {
        case containerUnavailable
        case manifestMissing
        case payloadTooLarge
        case expired
        case corrupt

        var errorDescription: String? {
            switch self {
            case .containerUnavailable: "Roundhouse couldn't reach its shared storage."
            case .manifestMissing: "This shared item was already imported or has expired."
            case .payloadTooLarge: "That item is too large to import."
            case .expired: "This shared item has expired."
            case .corrupt: "This shared item couldn't be verified and was removed."
            }
        }
    }

    private let inboxURLProvider: @Sendable () -> URL?
    private let beforeReadyCommit: (@Sendable () async -> Void)?
    private let beforeAcknowledge: (@Sendable () throws -> Void)?

    init(
        inboxURLProvider: @escaping @Sendable () -> URL? = ShareStagingStore.defaultInboxURL,
        beforeReadyCommit: (@Sendable () async -> Void)? = nil,
        beforeAcknowledge: (@Sendable () throws -> Void)? = nil
    ) {
        self.inboxURLProvider = inboxURLProvider
        self.beforeReadyCommit = beforeReadyCommit
        self.beforeAcknowledge = beforeAcknowledge
    }

    static func defaultInboxURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ShareAppGroup.identifier)?
            .appendingPathComponent(ShareAppGroup.inboxDirectoryName, isDirectory: true)
    }

    private var inboxURL: URL? { inboxURLProvider() }

    @discardableResult
    func stage(
        payload: Data,
        kind: ShareManifest.Kind,
        suggestedFilename: String?
    ) async throws -> ShareManifest {
        guard ShareImportLimits.isSizeAllowed(payload.count) else { throw StoreError.payloadTooLarge }
        guard let inboxURL else { throw StoreError.containerUnavailable }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        purgeInvalidReadyItems(in: inboxURL)

        let id = UUID()
        let stagingURL = stagingDirectoryURL(for: id, in: inboxURL)
        let readyURL = readyDirectoryURL(for: id, in: inboxURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingURL) }

        let payloadFilename = Self.payloadFilename(for: id)
        try payload.write(
            to: stagingURL.appendingPathComponent(payloadFilename),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )

        let manifest = ShareManifest(
            id: id,
            createdAt: Date(),
            kind: kind,
            payloadFilename: payloadFilename,
            suggestedFilename: suggestedFilename,
            sizeBytes: payload.count
        )
        try JSONEncoder().encode(manifest).write(
            to: manifestFileURL(for: id, in: stagingURL),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )

        // Tests suspend here to prove a second store cannot discover or purge an in-flight item.
        // In production this closure is nil and the next operation is the atomic ready commit.
        if let beforeReadyCommit { await beforeReadyCommit() }
        try fileManager.moveItem(at: stagingURL, to: readyURL)
        return manifest
    }

    /// All fully committed items currently staged and not expired, oldest first. Ready directories
    /// are the only new-format discovery surface. Legacy flat manifests remain readable so an item
    /// staged by the previous extension version survives an app update.
    func pendingManifestIDs() -> [UUID] {
        guard let inboxURL else { return [] }
        purgeInvalidReadyItems(in: inboxURL)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var found: [(id: UUID, createdAt: Date)] = []
        var foundIDs = Set<UUID>()

        for url in entries {
            if let id = Self.readyDirectoryID(from: url),
               let manifest = Self.readManifest(
                   at: manifestFileURL(for: id, in: url),
                   expectedID: id
               ),
               !manifest.isExpired(),
               foundIDs.insert(id).inserted {
                found.append((id, manifest.createdAt))
            } else if let id = Self.legacyManifestID(from: url),
                      let manifest = Self.readManifest(at: url, expectedID: id),
                      !manifest.isExpired(),
                      foundIDs.insert(id).inserted {
                found.append((id, manifest.createdAt))
            }
        }
        return found.sorted { $0.createdAt < $1.createdAt }.map(\.id)
    }

    /// Reads a validated snapshot without changing the durable item. Keeping the ready directory
    /// in place makes termination during OCR or review recoverable on the next launch.
    func lease(manifestID: UUID) throws -> Lease {
        guard let inboxURL else { throw StoreError.containerUnavailable }
        let readyURL = readyDirectoryURL(for: manifestID, in: inboxURL)
        if Self.isDirectory(readyURL) {
            return try validatedLease(
                manifestID: manifestID,
                baseURL: readyURL,
                storage: .readyDirectory
            )
        }
        return try validatedLease(
            manifestID: manifestID,
            baseURL: inboxURL,
            storage: .legacyFlatFiles
        )
    }

    /// Commits the single-use handoff. New-format acknowledgment first atomically renames the
    /// ready directory to a hidden name, so no concurrent scan can rediscover it, then removes it.
    /// Legacy acknowledgment removes the manifest ready marker before its payload.
    func acknowledge(_ lease: Lease) throws {
        guard let inboxURL else { throw StoreError.containerUnavailable }
        try beforeAcknowledge?()

        // Refuse to acknowledge a different item that somehow replaced the leased files. This is
        // the integrity check at the destructive boundary.
        let current = try self.lease(manifestID: lease.id)
        guard current.storage == lease.storage,
              current.manifest == lease.manifest,
              current.payload == lease.payload else {
            throw StoreError.corrupt
        }

        switch lease.storage {
        case .readyDirectory:
            let readyURL = readyDirectoryURL(for: lease.id, in: inboxURL)
            let acknowledgedURL = inboxURL.appendingPathComponent(
                ".\(lease.id.uuidString)\(Self.acknowledgedDirectoryMarker)\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try FileManager.default.moveItem(at: readyURL, to: acknowledgedURL)
            } catch {
                if !Self.isDirectory(readyURL) { throw StoreError.manifestMissing }
                throw StoreError.containerUnavailable
            }
            try? FileManager.default.removeItem(at: acknowledgedURL)

        case .legacyFlatFiles:
            let manifestURL = manifestFileURL(for: lease.id, in: inboxURL)
            do {
                try FileManager.default.removeItem(at: manifestURL)
            } catch {
                if !FileManager.default.fileExists(atPath: manifestURL.path) {
                    throw StoreError.manifestMissing
                }
                throw StoreError.containerUnavailable
            }
            try? FileManager.default.removeItem(
                at: inboxURL.appendingPathComponent(Self.payloadFilename(for: lease.id))
            )
        }
    }

    private static let manifestSuffix = ".manifest.json"
    private static let readyDirectorySuffix = ".share"
    private static let stagingDirectoryMarker = ".staging-"
    private static let acknowledgedDirectoryMarker = ".acknowledged-"

    static func payloadFilename(for id: UUID) -> String {
        "\(id.uuidString).payload"
    }

    private func validatedLease(
        manifestID: UUID,
        baseURL: URL,
        storage: Lease.Storage
    ) throws -> Lease {
        let manifestURL = manifestFileURL(for: manifestID, in: baseURL)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw StoreError.manifestMissing
        }

        let expectedPayloadFilename = Self.payloadFilename(for: manifestID)
        let payloadURL = baseURL.appendingPathComponent(expectedPayloadFilename)
        guard let manifest = try? JSONDecoder().decode(ShareManifest.self, from: manifestData),
              manifest.id == manifestID,
              manifest.payloadFilename == expectedPayloadFilename else {
            removeItem(manifestID: manifestID, storage: storage, from: baseURL)
            throw StoreError.corrupt
        }
        guard !manifest.isExpired() else {
            removeItem(manifestID: manifestID, storage: storage, from: baseURL)
            throw StoreError.expired
        }
        guard ShareImportLimits.isSizeAllowed(manifest.sizeBytes) else {
            removeItem(manifestID: manifestID, storage: storage, from: baseURL)
            throw StoreError.payloadTooLarge
        }
        guard let payload = try? Data(contentsOf: payloadURL),
              payload.count == manifest.sizeBytes,
              ShareImportLimits.isSizeAllowed(payload.count) else {
            removeItem(manifestID: manifestID, storage: storage, from: baseURL)
            throw StoreError.corrupt
        }
        return Lease(manifest: manifest, payload: payload, storage: storage)
    }

    private func manifestFileURL(for id: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString)\(Self.manifestSuffix)")
    }

    private func readyDirectoryURL(for id: UUID, in inboxURL: URL) -> URL {
        inboxURL.appendingPathComponent("\(id.uuidString)\(Self.readyDirectorySuffix)", isDirectory: true)
    }

    private func stagingDirectoryURL(for id: UUID, in inboxURL: URL) -> URL {
        inboxURL.appendingPathComponent(
            ".\(id.uuidString)\(Self.stagingDirectoryMarker)\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static func readManifest(at url: URL, expectedID: UUID) -> ShareManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ShareManifest.self, from: data),
              manifest.id == expectedID,
              manifest.payloadFilename == payloadFilename(for: expectedID) else {
            return nil
        }
        return manifest
    }

    /// Invalid ready items are safe to remove because the atomic rename proves their writer
    /// finished. Hidden staging directories are retained for the full share lifetime, which makes
    /// suspension indistinguishable from an active writer until the staged item would be expired
    /// anyway. Legacy orphan payloads are intentionally ignored because they have no atomic marker.
    private func purgeInvalidReadyItems(in inboxURL: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        for url in entries {
            if let id = Self.readyDirectoryID(from: url) {
                guard let manifest = Self.readManifest(
                    at: manifestFileURL(for: id, in: url),
                    expectedID: id
                ), !manifest.isExpired() else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
            } else if Self.ownedHiddenDirectoryID(
                from: url,
                marker: Self.stagingDirectoryMarker
            ) != nil {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modifiedAt = values?.contentModificationDate,
                      Date().timeIntervalSince(modifiedAt) > ShareManifest.maxAge else {
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            } else if Self.ownedHiddenDirectoryID(
                from: url,
                marker: Self.acknowledgedDirectoryMarker
            ) != nil {
                // The ready-directory rename already committed the user's disposition; only
                // best-effort cleanup can have failed after this point.
                try? FileManager.default.removeItem(at: url)
            } else if let id = Self.legacyManifestID(from: url) {
                guard let manifest = Self.readManifest(at: url, expectedID: id),
                      !manifest.isExpired() else {
                    removeLegacyFiles(manifestID: id, in: inboxURL)
                    continue
                }
            }
        }
    }

    private func removeItem(manifestID: UUID, storage: Lease.Storage, from baseURL: URL) {
        switch storage {
        case .readyDirectory:
            try? FileManager.default.removeItem(at: baseURL)
        case .legacyFlatFiles:
            removeLegacyFiles(manifestID: manifestID, in: baseURL)
        }
    }

    private func removeLegacyFiles(manifestID: UUID, in inboxURL: URL) {
        try? FileManager.default.removeItem(at: manifestFileURL(for: manifestID, in: inboxURL))
        try? FileManager.default.removeItem(
            at: inboxURL.appendingPathComponent(Self.payloadFilename(for: manifestID))
        )
    }

    private static func readyDirectoryID(from url: URL) -> UUID? {
        let filename = url.lastPathComponent
        guard filename.hasSuffix(readyDirectorySuffix), isDirectory(url) else { return nil }
        return UUID(uuidString: String(filename.dropLast(readyDirectorySuffix.count)))
    }

    private static func legacyManifestID(from url: URL) -> UUID? {
        let filename = url.lastPathComponent
        guard filename.hasSuffix(manifestSuffix), !isDirectory(url) else { return nil }
        return UUID(uuidString: String(filename.dropLast(manifestSuffix.count)))
    }

    /// Recognizes only directories created by this store. A loose substring check could delete an
    /// unrelated directory in the shared container if its name happened to contain our marker.
    private static func ownedHiddenDirectoryID(from url: URL, marker: String) -> UUID? {
        guard isDirectory(url) else { return nil }
        let filename = url.lastPathComponent
        guard filename.first == "." else { return nil }

        let body = filename.dropFirst()
        let uuidCharacterCount = 36
        guard body.count == uuidCharacterCount + marker.count + uuidCharacterCount else {
            return nil
        }

        let idEnd = body.index(body.startIndex, offsetBy: uuidCharacterCount)
        let idText = body[..<idEnd]
        let remainder = body[idEnd...]
        guard remainder.hasPrefix(marker) else { return nil }
        let nonceText = remainder.dropFirst(marker.count)
        guard let id = UUID(uuidString: String(idText)),
              UUID(uuidString: String(nonceText)) != nil else {
            return nil
        }
        return id
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
