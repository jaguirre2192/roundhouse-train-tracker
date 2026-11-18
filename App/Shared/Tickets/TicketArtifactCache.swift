import CryptoKit
import Foundation

actor TicketArtifactCache {
    enum Kind: String { case original, barcode }

    func load(ticketID: String, kind: Kind) -> Data? {
        try? Data(contentsOf: fileURL(ticketID: ticketID, kind: kind))
    }

    func save(_ data: Data, ticketID: String, kind: Kind) throws {
        let directory = try directoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try data.write(to: fileURL(ticketID: ticketID, kind: kind), options: [.atomic, .completeFileProtection])
    }

    func remove(ticketIDs: [String]) {
        for ticketID in ticketIDs {
            for kind in [Kind.original, .barcode] {
                try? FileManager.default.removeItem(at: fileURL(ticketID: ticketID, kind: kind))
            }
        }
    }

    func removeAll() {
        guard let directory = try? directoryURL() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(ticketID: String, kind: Kind) -> URL {
        let digest = SHA256.hash(data: Data(ticketID.utf8)).map { String(format: "%02x", $0) }.joined()
        return (try? directoryURL())?.appending(path: "\(digest).\(kind.rawValue)")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(digest).\(kind.rawValue)")
    }

    private func directoryURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "ImportedTickets", directoryHint: .isDirectory)
    }
}
