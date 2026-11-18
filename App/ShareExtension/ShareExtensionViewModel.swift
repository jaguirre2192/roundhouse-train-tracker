import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Everything the extension itself does: validate the shared item and stage it into the App Group
/// container. A Share extension has no way to launch its containing app, so the extension's job
/// ends at staging — the host app scans the App Group inbox on its own (launch + becoming active)
/// and does the real parsing/review work whenever the person next opens it.
@MainActor
@Observable
final class ShareExtensionViewModel {
    enum State: Equatable {
        case working
        case success
        case rejected(String)
        case failed(String)
    }

    private(set) var state: State = .working

    private let store: ShareStagingStore

    init(store: ShareStagingStore = ShareStagingStore()) {
        self.store = store
    }

    func start(context: NSExtensionContext?) async {
        let providers = (context?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            state = .rejected("Roundhouse couldn't find anything to import.")
            return
        }
        guard let choice = ShareImportLimits.preferredAttachment(
            in: providers.map(\.registeredTypeIdentifiers)
        ) else {
            state = .rejected("Roundhouse can't import this kind of item yet.")
            return
        }
        let provider = providers[choice.index]

        do {
            let payload = try await Self.loadPayload(from: provider, typeIdentifier: choice.typeIdentifier)
            guard ShareImportLimits.isSizeAllowed(payload.count) else {
                state = .rejected("That item is too large to import.")
                return
            }
            _ = try await store.stage(
                payload: payload,
                kind: choice.kind,
                suggestedFilename: provider.suggestedName
            )
            state = .success
        } catch ShareImportLimits.PayloadError.tooLarge {
            state = .rejected("That item is too large to import.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func loadPayload(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch item {
                case let data as Data:
                    continuation.resume(returning: data)
                case let url as URL:
                    if url.isFileURL {
                        // Check the size before reading so an oversized file never loads.
                        do {
                            continuation.resume(returning: try ShareImportLimits.readFile(at: url))
                        } catch ShareImportLimits.PayloadError.tooLarge {
                            continuation.resume(throwing: ShareImportLimits.PayloadError.tooLarge)
                        } catch {
                            continuation.resume(throwing: CocoaError(.fileReadUnknown))
                        }
                    } else {
                        // Never fetch a network URL's contents here — that would be an
                        // unbounded, unreviewed network request from inside the extension.
                        // Stage the URL text itself; the host app decides what to do with it.
                        continuation.resume(returning: Data(url.absoluteString.utf8))
                    }
                case let text as String:
                    continuation.resume(returning: Data(text.utf8))
                case let image as UIImage:
                    if let data = image.pngData() {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    }
                default:
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
