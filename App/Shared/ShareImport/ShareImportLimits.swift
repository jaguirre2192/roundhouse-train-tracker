import Foundation
import UniformTypeIdentifiers

/// Type and size rules the Share extension enforces before ever writing to the shared container,
/// and that the host app re-checks before trusting a staged manifest.
enum ShareImportLimits {
    static let maxPayloadBytes = 8 * 1024 * 1024

    static func kind(forTypeIdentifier typeIdentifier: String) -> ShareManifest.Kind? {
        guard let type = UTType(typeIdentifier) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .url), !type.conforms(to: .fileURL) { return .url }
        if isEmailType(type) { return .emailMessage }
        if type.conforms(to: .plainText) { return .text }
        return nil
    }

    static func isAcceptedTypeIdentifier(_ typeIdentifier: String) -> Bool {
        kind(forTypeIdentifier: typeIdentifier) != nil
    }

    static func isSizeAllowed(_ sizeBytes: Int) -> Bool {
        sizeBytes > 0 && sizeBytes <= maxPayloadBytes
    }

    enum PayloadError: Error, Equatable {
        case tooLarge
    }

    /// Reads a shared file only after its size is known to fit, so an oversized file is never
    /// loaded into the extension's small memory budget.
    static func readFile(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, size > maxPayloadBytes { throw PayloadError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxPayloadBytes else { throw PayloadError.tooLarge }
        return data
    }

    /// Chooses which shared attachment to import. Hosts such as Mail put a text body before the
    /// ticket, so a PDF or image anywhere in the share wins over text and links.
    static func preferredAttachment(
        in attachments: [[String]]
    ) -> (index: Int, typeIdentifier: String, kind: ShareManifest.Kind)? {
        var best: (index: Int, typeIdentifier: String, kind: ShareManifest.Kind, rank: Int)?
        for (index, typeIdentifiers) in attachments.enumerated() {
            for typeIdentifier in typeIdentifiers {
                guard let kind = kind(forTypeIdentifier: typeIdentifier) else { continue }
                let rank = priority(of: kind)
                if best == nil || rank < best!.rank {
                    best = (index, typeIdentifier, kind, rank)
                }
                break
            }
        }
        return best.map { ($0.index, $0.typeIdentifier, $0.kind) }
    }

    private static func priority(of kind: ShareManifest.Kind) -> Int {
        switch kind {
        case .pdf: 0
        case .image: 1
        case .emailMessage: 2
        case .url: 3
        case .text: 4
        }
    }

    private static func isEmailType(_ type: UTType) -> Bool {
        if let emailMessage = UTType("public.email-message"), type.conforms(to: emailMessage) {
            return true
        }
        return type.preferredFilenameExtension?.lowercased() == "eml"
    }
}
