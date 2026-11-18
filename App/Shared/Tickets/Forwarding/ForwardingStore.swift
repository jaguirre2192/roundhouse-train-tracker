import Foundation
import Observation

/// Owns the "Forward Ticket" address and the tickets it has received. Authenticates exclusively
/// through `AccountSessionStore` (never the App Group), and mirrors the account lifecycle: loaded
/// on sign-in/restore, cleared on sign-out.
@MainActor
@Observable
final class ForwardingStore {
    enum State: Equatable {
        case signInRequired
        case loading
        case inactive
        case active
    }

    private(set) var state: State = .signInRequired
    private(set) var address: String?
    private(set) var createdAt: String?
    private(set) var rotatedAt: String?
    private(set) var tickets: [ForwardedTicketSummary] = []
    private(set) var isWorking = false
    /// A failure of an action the person just took (create, rotate, disable, delete). Shown
    /// inline next to that action.
    private(set) var errorMessage: String?
    /// A failure of automatic loading on sign-in or foreground. Never presented modally: the
    /// forwarding screen and the forwarded tickets list show it inline with saved content.
    private(set) var refreshIssue: String?

    private let client: ForwardingClient
    private let barcodeCache: TicketArtifactCache
    private var artifactCache: [String: (data: Data, mimeType: String)] = [:]
    private var currentUserID: String?
    private var currentSessionToken: String?
    private var didLoad = false
    private var sessionGeneration = 0
    private var activeRequestID: UUID?

    private struct RequestContext: Equatable {
        let userID: String
        let sessionToken: String
        let generation: Int
        let requestID: UUID
    }

    private struct SessionSnapshot: Equatable {
        let userID: String
        let sessionToken: String
        let generation: Int
    }

    init(
        client: ForwardingClient = ForwardingClient(), barcodeCache: TicketArtifactCache = TicketArtifactCache()
    ) {
        self.client = client
        self.barcodeCache = barcodeCache
    }

    /// Call after account restore completes with a signed-in user, and again on every sign-in.
    func signedIn(userID: String) async {
        let sessionToken = AccountSessionStore.load()
        guard currentUserID != userID || currentSessionToken != sessionToken else {
            await refresh()
            return
        }
        invalidatePendingWork()
        currentUserID = userID
        currentSessionToken = sessionToken
        createdAt = nil
        rotatedAt = nil
        tickets = []
        artifactCache = [:]
        errorMessage = nil
        refreshIssue = nil
        address = ForwardingAddressCache.load(userID: userID)
        state = address == nil ? .loading : .active
        didLoad = false
        await refresh()
    }

    func signedOut() {
        invalidatePendingWork()
        currentUserID = nil
        currentSessionToken = nil
        address = nil
        createdAt = nil
        rotatedAt = nil
        tickets = []
        artifactCache = [:]
        didLoad = false
        errorMessage = nil
        refreshIssue = nil
        state = .signInRequired
    }

    func refresh() async {
        guard currentUserID != nil else { state = .signInRequired; return }
        guard let context = beginRequest(isBackground: true) else { return }
        defer { finishRequest(context) }
        if !didLoad, address == nil { state = .loading }
        do {
            async let statusTask = client.aliasStatus(sessionToken: context.sessionToken)
            async let ticketsTask = client.tickets(sessionToken: context.sessionToken)
            let status = try await statusTask
            let refreshedTickets = try await ticketsTask
            guard isCurrent(context) else { return }
            tickets = refreshedTickets
            apply(status: status, userID: context.userID)
            didLoad = true
            refreshIssue = nil
        } catch {
            guard isCurrent(context) else { return }
            refreshIssue = error.localizedDescription
            if !didLoad { state = address == nil ? .inactive : .active }
        }
    }

    func createAddress() async {
        await performAliasAction { token in try await client.createAlias(sessionToken: token) }
    }

    func rotateAddress() async {
        await performAliasAction { token in try await client.rotateAlias(sessionToken: token) }
    }

    func disable() async {
        guard let context = beginRequest() else { return }
        defer { finishRequest(context) }
        do {
            try await client.revokeAlias(sessionToken: context.sessionToken)
            guard isCurrent(context) else { return }
            address = nil
            createdAt = nil
            rotatedAt = nil
            ForwardingAddressCache.clear(userID: context.userID)
            state = .inactive
        } catch {
            guard isCurrent(context) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Returns true only when the ticket was deleted, so callers never dismiss on failure.
    @discardableResult
    func deleteTicket(id: String) async -> Bool {
        guard let context = beginRequest() else { return false }
        defer { finishRequest(context) }
        do {
            try await client.deleteTicket(ticketID: id, sessionToken: context.sessionToken)
            guard isCurrent(context) else { return false }
            tickets.removeAll { $0.id == id }
            let snapshot = try sessionSnapshot()
            let cacheKey = cacheTicketID(id, snapshot: snapshot)
            artifactCache.removeValue(forKey: cacheKey)
            await barcodeCache.remove(ticketIDs: [cacheKey])
            return true
        } catch {
            guard isCurrent(context) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func dismissError() { errorMessage = nil }

    private func performAliasAction(
        _ action: (String) async throws -> ForwardingAliasStatus
    ) async {
        guard let context = beginRequest() else { return }
        defer { finishRequest(context) }
        do {
            let status = try await action(context.sessionToken)
            guard isCurrent(context) else { return }
            apply(status: status, userID: context.userID)
        } catch {
            guard isCurrent(context) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func beginRequest(isBackground: Bool = false) -> RequestContext? {
        guard !isWorking, let currentUserID else { return nil }
        guard let sessionToken = currentSessionToken,
              AccountSessionStore.load() == sessionToken else {
            let message = ForwardingClient.ClientError.signedOut.localizedDescription
            if isBackground { refreshIssue = message } else { errorMessage = message }
            if !didLoad { state = address == nil ? .inactive : .active }
            return nil
        }
        let context = RequestContext(
            userID: currentUserID,
            sessionToken: sessionToken,
            generation: sessionGeneration,
            requestID: UUID()
        )
        activeRequestID = context.requestID
        isWorking = true
        errorMessage = nil
        return context
    }

    private func finishRequest(_ context: RequestContext) {
        guard activeRequestID == context.requestID else { return }
        activeRequestID = nil
        isWorking = false
    }

    private func isCurrent(_ context: RequestContext) -> Bool {
        currentUserID == context.userID
            && currentSessionToken == context.sessionToken
            && AccountSessionStore.load() == context.sessionToken
            && sessionGeneration == context.generation
            && activeRequestID == context.requestID
    }

    private func sessionSnapshot() throws -> SessionSnapshot {
        guard let currentUserID,
              let sessionToken = currentSessionToken,
              AccountSessionStore.load() == sessionToken else {
            throw ForwardingClient.ClientError.signedOut
        }
        return SessionSnapshot(
            userID: currentUserID,
            sessionToken: sessionToken,
            generation: sessionGeneration
        )
    }

    private func isCurrent(_ snapshot: SessionSnapshot) -> Bool {
        currentUserID == snapshot.userID
            && currentSessionToken == snapshot.sessionToken
            && AccountSessionStore.load() == snapshot.sessionToken
            && sessionGeneration == snapshot.generation
    }

    private func cacheTicketID(_ ticketID: String, snapshot: SessionSnapshot) -> String {
        "forwarding:\(snapshot.userID):\(snapshot.sessionToken):\(ticketID)"
    }

    private func invalidatePendingWork() {
        sessionGeneration &+= 1
        activeRequestID = nil
        isWorking = false
    }

    private func apply(status: ForwardingAliasStatus, userID: String) {
        if !status.active {
            address = nil
            ForwardingAddressCache.clear(userID: userID)
        } else if let revealedAddress = status.address {
            address = revealedAddress
            ForwardingAddressCache.save(revealedAddress, userID: userID)
        }
        createdAt = status.createdAt
        rotatedAt = status.rotatedAt
        state = status.active ? .active : .inactive
    }
}

extension ForwardingStore: TicketArtifactSource {
    func cachedBarcode(ticketID: String) async -> Data? {
        guard let snapshot = try? sessionSnapshot() else { return nil }
        let scopedTicketID = cacheTicketID(ticketID, snapshot: snapshot)
        let data = await barcodeCache.load(ticketID: scopedTicketID, kind: .barcode)
        guard isCurrent(snapshot) else { return nil }
        return data
    }

    func artifactData(ticketID: String) async throws -> (data: Data, mimeType: String) {
        let snapshot = try sessionSnapshot()
        let scopedTicketID = cacheTicketID(ticketID, snapshot: snapshot)
        if let cached = artifactCache[scopedTicketID] {
            guard isCurrent(snapshot) else { throw CancellationError() }
            return cached
        }
        let result = try await client.artifact(ticketID: ticketID, sessionToken: snapshot.sessionToken)
        guard isCurrent(snapshot) else { throw CancellationError() }
        artifactCache[scopedTicketID] = result
        return result
    }

    func saveBarcode(_ data: Data, ticketID: String) async {
        guard let snapshot = try? sessionSnapshot(), isCurrent(snapshot) else { return }
        let scopedTicketID = cacheTicketID(ticketID, snapshot: snapshot)
        do {
            try await barcodeCache.save(data, ticketID: scopedTicketID, kind: .barcode)
            guard isCurrent(snapshot) else {
                await barcodeCache.remove(ticketIDs: [scopedTicketID])
                return
            }
        } catch {
            return
        }
    }
}
