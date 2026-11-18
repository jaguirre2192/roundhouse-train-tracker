import Foundation
import Observation
import TrainTrackerCore

/// The saved journey or individual train a ticket is attached to.
enum JourneyTicketOwner: Hashable, Sendable {
    case plan(UUID)
    case trip(String)
}

/// Root-owned coordination for adding journeys: one presentation at a time, queued shared
/// imports, ticket linking after a confirmed save, and a single reversible Undo.
@MainActor
@Observable
final class JourneyIntakeModel {
    struct ReviewRequest: Identifiable, Equatable {
        let id: UUID
        let suggestion: TicketRouteSuggestion
        /// Set when the review started from a saved original ticket.
        let ticketID: UUID?
        /// Snapshots taken when the review starts, so the sheet does not re-read the vault.
        let ticketDetails: TicketTextDetails?
        let linkedPlanIDs: Set<UUID>

        @MainActor
        init(suggestion: TicketRouteSuggestion, ticketID: UUID?, vault: LocalJourneyTicketStore? = nil) {
            id = UUID()
            let ticket = ticketID.flatMap { vault?.ticket(id: $0) }
            self.suggestion = ticket?.suggestion ?? suggestion
            self.ticketID = ticketID
            ticketDetails = ticket?.details
            linkedPlanIDs = ticket?.linkedPlanIDs ?? []
        }
    }

    enum Presentation: Identifiable, Equatable {
        case addJourney(JourneyTicketOwner?)
        case review(ReviewRequest)

        var id: String {
            switch self {
            case let .addJourney(owner): "add-\(String(describing: owner))"
            case let .review(request): "review-\(request.id)"
            }
        }
    }

    /// Only additions made by one action are reversible. Pre-existing journeys, shared trains
    /// and original tickets are never deleted by Undo.
    struct UndoAction: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let removesPlanID: UUID?
        let unlinkTicketID: UUID?
        let owner: JourneyTicketOwner?
        /// A journey group removed by the person, put back by Undo.
        var restoresPlan: RemovedPlan? = nil
    }

    struct RemovedPlan: Equatable {
        let plan: TrackedJourneyPlan
        let index: Int
    }

    private(set) var presentation: Presentation?
    private(set) var undo: UndoAction?
    private(set) var errorMessage: String?
    private var queuedReviews: [ReviewRequest] = []
    /// Screens that present their own modal (for example the retailer browser) block root
    /// presentation, because SwiftUI cannot show a second sheet over them.
    private var localPresentationCount = 0
    @ObservationIgnored private var pendingDraft: TicketRouteSuggestion?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?

    let vault: LocalJourneyTicketStore
    let makeClient: @MainActor () -> any JourneySearching

    init(vault: LocalJourneyTicketStore, makeClient: @escaping @MainActor () -> any JourneySearching = { JourneySearchClient() }) {
        self.vault = vault
        self.makeClient = makeClient
    }

    // MARK: - Presentation

    func presentAddJourney(attachingTo owner: JourneyTicketOwner? = nil) {
        guard canPresent else { return }
        presentation = .addJourney(owner)
    }

    func review(ticket: LocalJourneyTicket) {
        present(ReviewRequest(suggestion: ticket.suggestion, ticketID: ticket.id, vault: vault))
    }

    /// Reviews without an original artifact (Calendar) are kept as unfinished drafts too.
    func review(suggestion: TicketRouteSuggestion, isEdited: Bool = false) {
        present(reviewRequest(for: suggestion, isEdited: isEdited))
    }

    /// One draft exists per Calendar event: an unedited suggestion resumes the saved draft, while
    /// edited details or a changed event revision replace it under the same draft identity.
    func reviewRequest(for suggestion: TicketRouteSuggestion, isEdited: Bool = false) -> ReviewRequest {
        if let ticket = vault.ticket(id: suggestion.id) {
            return ReviewRequest(suggestion: ticket.suggestion, ticketID: ticket.id, vault: vault)
        }
        var suggestion = suggestion
        if let saved = vault.reviews.first(where: { $0.id == suggestion.id }) {
            if !isEdited { suggestion = saved }
        } else if let source = suggestion.calendarSource,
                  let saved = vault.reviews.first(where: { $0.calendarSource?.eventKey == source.eventKey }) {
            suggestion = saved.calendarSource?.revision == source.revision && !isEdited
                ? saved
                : suggestion.revised(id: saved.id)
        }
        suggestion = suggestion.restoringMissingCalendarRoute()
        saveDraftNow(suggestion)
        return ReviewRequest(suggestion: suggestion, ticketID: nil)
    }

    func presentReview(_ request: ReviewRequest) {
        present(request)
    }

    /// A shared item has already been saved locally. Present it now, or after the current sheet.
    func sharedTicketSaved(_ ticket: LocalJourneyTicket) {
        // A repeated share of a ticket that already belongs to a journey needs no new review.
        guard ticket.isDraft else { return }
        guard !queuedReviews.contains(where: { $0.ticketID == ticket.id }) else { return }
        if case let .review(current) = presentation, current.ticketID == ticket.id { return }
        let request = ReviewRequest(suggestion: ticket.suggestion, ticketID: ticket.id, vault: vault)
        if canPresent, presentation == nil {
            presentation = .review(request)
        } else {
            queuedReviews.append(request)
        }
    }

    func dismissPresentation() {
        flushDraft()
        presentation = nil
        advanceQueue()
    }

    func beginLocalPresentation() {
        localPresentationCount += 1
    }

    func endLocalPresentation() {
        localPresentationCount = max(0, localPresentationCount - 1)
        advanceQueue()
    }

    private var canPresent: Bool { localPresentationCount == 0 }

    /// A screen-owned sheet or cover is up; it shows intake errors itself.
    var hasLocalPresentation: Bool { localPresentationCount > 0 }

    private func present(_ request: ReviewRequest) {
        if canPresent, presentation == nil || isPresentingAddJourney {
            presentation = .review(request)
        } else if !queuedReviews.contains(where: { $0.suggestion.id == request.suggestion.id }) {
            queuedReviews.append(request)
        }
    }

    private var isPresentingAddJourney: Bool {
        if case .addJourney = presentation { return true }
        return false
    }

    private func advanceQueue() {
        while canPresent, presentation == nil, !queuedReviews.isEmpty {
            let next = queuedReviews.removeFirst()
            if let ticketID = next.ticketID {
                guard let ticket = vault.ticket(id: ticketID), ticket.isDraft else { continue }
                presentation = .review(ReviewRequest(suggestion: ticket.suggestion, ticketID: ticketID, vault: vault))
            } else {
                presentation = .review(next)
            }
        }
    }

    // MARK: - Drafts

    /// Edits are coalesced so typing does not rewrite the index on every keystroke.
    func saveDraft(_ suggestion: TicketRouteSuggestion) {
        pendingDraft = suggestion
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flushDraft()
        }
    }

    func flushDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard let draft = pendingDraft else { return }
        pendingDraft = nil
        saveDraftNow(draft)
    }

    private func saveDraftNow(_ suggestion: TicketRouteSuggestion) {
        do {
            try vault.saveDraft(suggestion)
        } catch {
            report(error.localizedDescription)
        }
    }

    // MARK: - Completion

    /// Called only after Track Journey saved successfully.
    func completeReview(_ request: ReviewRequest, plan: TrackedJourneyPlan, created: Bool, navigation: AppNavigationModel) {
        pendingDraft = nil
        draftSaveTask?.cancel()
        var linked = false
        do {
            if let ticketID = request.ticketID {
                linked = try vault.link(id: ticketID, planID: plan.id)
            } else {
                try vault.discardReview(id: request.suggestion.id)
            }
        } catch {
            report("Your journey was saved, but the ticket couldn't be attached. Open the journey and attach it again.")
        }
        presentation = nil
        undo = (created || linked) ? UndoAction(
            message: created ? "Journey added to My Trips" : "Ticket attached to your journey",
            removesPlanID: created ? plan.id : nil,
            unlinkTicketID: linked ? request.ticketID : nil,
            owner: .plan(plan.id)
        ) : nil
        navigation.open(.trips)
        advanceQueue()
    }

    /// An equivalent journey is already saved: open it and attach this ticket to it.
    func openExisting(_ request: ReviewRequest, plan: TrackedJourneyPlan, navigation: AppNavigationModel) {
        pendingDraft = nil
        draftSaveTask?.cancel()
        var linked = false
        do {
            if let ticketID = request.ticketID {
                linked = try vault.link(id: ticketID, planID: plan.id)
            } else {
                try vault.discardReview(id: request.suggestion.id)
            }
        } catch {
            report("Your saved journey is open, but the ticket couldn't be attached. Attach it from the journey.")
        }
        presentation = nil
        undo = linked ? UndoAction(message: "Ticket attached to your saved journey", removesPlanID: nil, unlinkTicketID: request.ticketID, owner: .plan(plan.id)) : nil
        navigation.openJourneyPlan(id: plan.id)
        advanceQueue()
    }

    /// Explicit attachment from a journey or train screen.
    func attach(ticketID: UUID, to owner: JourneyTicketOwner) {
        do {
            let linked: Bool
            switch owner {
            case let .plan(planID): linked = try vault.link(id: ticketID, planID: planID)
            case let .trip(tripID): linked = try vault.link(id: ticketID, tripID: tripID)
            }
            undo = linked ? UndoAction(message: "Ticket attached", removesPlanID: nil, unlinkTicketID: ticketID, owner: owner) : nil
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Unlinks first, because that never removes anything, then removes a journey this action created.
    func performUndo(planLibrary: JourneyPlanLibrary) {
        guard let undo else { return }
        if let removed = undo.restoresPlan {
            do {
                try planLibrary.restorePlan(removed.plan, at: removed.index)
            } catch {
                report("Couldn't restore that journey group. Your trains are still in My Trips.")
                return
            }
        }
        if let ticketID = undo.unlinkTicketID, let owner = undo.owner, vault.ticket(id: ticketID) != nil {
            do {
                switch owner {
                case let .plan(planID): try vault.unlink(id: ticketID, planID: planID)
                case let .trip(tripID): try vault.unlink(id: ticketID, tripID: tripID)
                }
            } catch {
                report("Couldn't undo that change. Your journey and ticket are unchanged. Try again.")
                return
            }
        }
        if let planID = undo.removesPlanID, planLibrary.plans.contains(where: { $0.id == planID }) {
            do {
                // Shared and pre-existing trains are preserved by the library's ownership rules.
                try planLibrary.removePlanAndStopTrackingChildren(id: planID)
            } catch {
                self.undo = nil
                report("The ticket was detached, but the journey couldn't be removed. Remove it from the journey screen.")
                return
            }
        }
        self.undo = nil
    }

    func clearUndo() {
        undo = nil
    }

    /// Offers Undo after Remove Journey Group, which keeps the trains and drops only the grouping.
    func offerUndo(restoring removed: RemovedPlan) {
        undo = UndoAction(
            message: JourneySearchCopy.Plan.groupRemoved,
            removesPlanID: nil,
            unlinkTicketID: nil,
            owner: nil,
            restoresPlan: removed
        )
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Repeated identical failures (for example while typing with no storage) show one message.
    func report(_ message: String) {
        guard errorMessage != message else { return }
        errorMessage = message
    }
}
