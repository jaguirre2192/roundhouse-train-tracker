import Foundation
import Observation

@MainActor
@Observable
final class TicketInbox {
    private(set) var connections: [GmailConnection] = []
    private(set) var tickets: [TrainTicket] = []
    private(set) var isConnected = false
    private(set) var isWorking = false
    private(set) var lastImportedCount: Int?
    private(set) var errorMessage: String?

    private let client: GmailInboxClient
    private let artifactCache = TicketArtifactCache()
    private var didRestore = false

    init(client: GmailInboxClient = GmailInboxClient()) {
        self.client = client
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        guard await client.hasSession() else { return }
        await refresh()
    }

    func authorizationURL() async -> URL? {
        await perform { try await client.authorizationURL() }
    }

    func handleCallback(_ url: URL) async {
        guard Self.isCallback(url) else { return }
        await perform {
            try await client.completeConnection(from: url)
            try await reload()
        }
    }

    func refresh() async {
        await perform { try await reload() }
    }

    func scanNow() async {
        await perform {
            lastImportedCount = try await client.scan()
            try await reload()
        }
    }

    func disconnect(_ connection: GmailConnection) async {
        await perform {
            let removedTicketIDs = tickets.filter { $0.emailAddress == connection.emailAddress }.map(\.id)
            try await client.disconnect(connection)
            await artifactCache.remove(ticketIDs: removedTicketIDs)
            try await reload()
        }
    }

    func reset() async {
        connections = []
        tickets = []
        isConnected = false
        isWorking = false
        lastImportedCount = nil
        errorMessage = nil
        didRestore = false
        await artifactCache.removeAll()
    }

    func dismissError() { errorMessage = nil }

    nonisolated static func isCallback(_ url: URL) -> Bool {
        if url.scheme == "traintracker", url.host == "gmail-connected" { return true }
        return TrainTrackerBackendConfiguration.isTrustedCallback(url, path: "/gmail-connected")
    }

    private func reload() async throws {
        async let loadedConnections = client.connections()
        async let loadedTickets = client.tickets()
        connections = try await loadedConnections
        tickets = try await loadedTickets
        isConnected = !connections.isEmpty
    }

    private func perform<Value>(_ operation: () async throws -> Value) async -> Value? {
        guard !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            return try await operation()
        } catch {
            if !(await client.hasSession()) {
                connections = []
                tickets = []
                isConnected = false
            }
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

extension TicketInbox: TicketArtifactSource {
    func cachedBarcode(ticketID: String) async -> Data? {
        await artifactCache.load(ticketID: ticketID, kind: .barcode)
    }

    func artifactData(ticketID: String) async throws -> (data: Data, mimeType: String) {
        guard let ticket = tickets.first(where: { $0.id == ticketID }), let artifact = ticket.artifact else {
            throw TicketArtifactError.unavailable
        }
        if let cached = await artifactCache.load(ticketID: ticketID, kind: .original) {
            return (cached, artifact.mimeType)
        }
        let data = try await client.artifact(ticketID: ticketID)
        try await artifactCache.save(data, ticketID: ticketID, kind: .original)
        return (data, artifact.mimeType)
    }

    func saveBarcode(_ data: Data, ticketID: String) async {
        try? await artifactCache.save(data, ticketID: ticketID, kind: .barcode)
    }
}
