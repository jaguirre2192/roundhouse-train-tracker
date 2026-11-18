import SwiftUI
import TrainTrackerCore

struct TicketPurchaseSavedSection: View {
    @Environment(TicketPurchaseStore.self) private var purchases
    @State private var confirmsReset = false
    @State private var errorMessage: String?

    var body: some View {
        if purchases.loadFailed || !purchases.drafts.isEmpty {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                Text("Ticket Searches").font(.title3.weight(.semibold))
                Text("Saved details for matching a journey on Omio. These are not booked tickets.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                if purchases.loadFailed {
                    Label("Saved ticket searches couldn’t be read.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                    Button("Reset ticket searches") { confirmsReset = true }
                        .frame(minHeight: 44)
                }
                ForEach(purchases.drafts) { draft in
                    NavigationLink {
                        TicketPurchaseView(journey: draft.journey, isResuming: true)
                    } label: {
                        HStack(spacing: TrainTrackerSpacing.space12) {
                            Image(systemName: "ticket")
                                .frame(width: LayoutMetrics.iconRailWidth)
                            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                                Text(draft.journey.routeTitle).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.ttTextPrimary)
                                if let leg = draft.journey.outbound.legs.first {
                                    Text(TicketPurchaseJourney.localDate(leg.departure, timeZone: leg.departureTimeZone))
                                        .font(.caption)
                                        .foregroundStyle(Color.ttTextSecondary)
                                }
                                Text(draft.journey.returnDirection == nil ? "One-way · Resume search" : "Round trip · Resume search")
                                    .font(.caption)
                                    .foregroundStyle(Color.ttTextSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(LayoutMetrics.cardInset)
                        .trainTrackerSurface(radius: TrainTrackerRadius.group)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resumeTicketSearch")
                    .contextMenu {
                        Button("Remove ticket search", role: .destructive) {
                            do { try purchases.remove(draft.id) }
                            catch { errorMessage = "The ticket search couldn’t be removed. Try again." }
                        }
                    }
                }
            }
            .confirmationDialog("Reset saved ticket searches?", isPresented: $confirmsReset, titleVisibility: .visible) {
                Button("Reset ticket searches", role: .destructive) {
                    do { try purchases.resetUnreadableSearches() }
                    catch { errorMessage = "Ticket searches couldn’t be reset. Try again." }
                }
            } message: {
                Text("Only the unreadable ticket-search data will be removed. Your tracked trains and imported tickets stay unchanged.")
            }
            .alert("Ticket searches", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
