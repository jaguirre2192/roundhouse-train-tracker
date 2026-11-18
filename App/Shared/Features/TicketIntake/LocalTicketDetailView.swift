import SwiftUI
import TrainTrackerCore
import UIKit

/// A ticket saved on this device: barcode first, then extracted details, the original and its
/// explicit journey links. Everything here is readable offline.
struct LocalTicketDetailView: View {
    let ticketID: UUID

    @Environment(LocalJourneyTicketStore.self) private var vault
    @Environment(JourneyIntakeModel.self) private var intake
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(TripLibrary.self) private var tripLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.journeyReviewRouter) private var reviewRouter
    @State private var barcode: Data?
    @State private var original: Data?
    @State private var isScanning = true
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        if let ticket = vault.ticket(id: ticketID) {
            content(ticket)
        } else {
            ContentUnavailableView("Ticket no longer saved", systemImage: "ticket",
                description: Text("Import the ticket again to keep it on this device."))
        }
    }

    private func content(_ ticket: LocalJourneyTicket) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    Text(ticket.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.ttTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Saved on this device", systemImage: "lock.iphone")
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TrainTrackerSpacing.space16)
                .railTicketStyle()
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if ticket.hasVisualOriginal {
                Section("Ticket") {
                    if let barcode, let image = UIImage(data: barcode) {
                        TicketBarcodeImage(image: image)
                    } else if isScanning {
                        HStack(spacing: TrainTrackerSpacing.space12) {
                            ProgressView()
                            Text("Finding barcode…")
                        }
                    } else if loadError == nil {
                        Text("No barcode was found. Show the original ticket below.")
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                }
                .trainTrackerRowSurface()
            }

            Section("Details") {
                if let number = ticket.suggestion.trainNumberGuess { LabeledContent("Train", value: number) }
                if let departure = departureText(ticket) { LabeledContent("Departure", value: departure) }
                if let coach = ticket.details.coach { LabeledContent("Coach", value: coach) }
                if let seat = ticket.details.seat { LabeledContent("Seat", value: seat) }
                if let booking = ticket.details.bookingReference { LabeledContent("Booking", value: booking) }
                LabeledContent("Source", value: ticket.filename ?? ticket.kindTitle)
            }
            .trainTrackerRowSurface()

            journeysSection(ticket)

            Section("Original") {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.ttStatusDelayed)
                } else if let original {
                    if ticket.hasVisualOriginal {
                        TicketAttachmentPreview(data: original, mimeType: ticket.mimeType)
                    } else {
                        Text(String(decoding: original.prefix(12_000), as: UTF8.self))
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                } else {
                    ProgressView()
                }
            }
            .trainTrackerRowSurface()

            Section {
                Button("Delete Ticket", role: .destructive) { showsDeleteConfirmation = true }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Deleting removes the saved original from this device. Your journeys and trains stay tracked.")
            }
            .trainTrackerRowSurface()
        }
        .trainTrackerListCanvas()
        .navigationTitle("Ticket")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ticketID) { await load(ticket) }
        .alert("Ticket", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("Delete this ticket?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Ticket", role: .destructive) {
                do {
                    try vault.remove(id: ticketID)
                    dismiss()
                } catch {
                    actionError = error.localizedDescription
                }
            }
        } message: {
            Text("The original ticket will be removed from this device. This can't be undone.")
        }
    }

    @ViewBuilder
    private func journeysSection(_ ticket: LocalJourneyTicket) -> some View {
        let plans = planLibrary.plans.filter { ticket.linkedPlanIDs.contains($0.id) }
        let trips = tripLibrary.trips.filter { ticket.linkedTripIDs.contains($0.id.rawValue) }
        Section {
            ForEach(plans) { plan in
                HStack {
                    NavigationLink {
                        JourneyPlanDetailView(plan: plan, planLibrary: planLibrary)
                    } label: {
                        Label("\(plan.origin.displayName) → \(plan.destination.displayName)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                .swipeActions {
                    Button("Detach") { unlink(ticket.id, .plan(plan.id)) }
                }
            }
            ForEach(trips) { trip in
                NavigationLink {
                    TripDetailView(trip: trip)
                } label: {
                    Label(trip.product, image: TrainTrackerSymbol.train)
                }
                .swipeActions {
                    Button("Detach") { unlink(ticket.id, .trip(trip.id.rawValue)) }
                }
            }
            if plans.isEmpty, trips.isEmpty {
                Text("Not attached to a saved journey yet.")
                    .foregroundStyle(Color.ttTextSecondary)
            }
            if (plans.isEmpty && trips.isEmpty) || (ticket.isDraft && ticket.suggestion.routeReviewReason == .multipleJourneys) {
                Button(ticket.isLinked ? "Review Remaining Journeys" : "Find and Track This Journey") {
                    if let reviewRouter {
                        reviewRouter.route(JourneyIntakeModel.ReviewRequest(suggestion: ticket.suggestion, ticketID: ticket.id, vault: vault))
                    } else {
                        intake.review(ticket: ticket)
                    }
                }
                    .accessibilityIdentifier("localTicketFindJourney")
                if ticket.isDraft {
                    Button(ticket.isLinked ? "Finish Reviewing Ticket" : "Keep Without a Journey") {
                        do { try vault.keepWithoutJourney(id: ticket.id) } catch { actionError = error.localizedDescription }
                    }
                }
            }
        } header: {
            Text("Journeys")
        } footer: {
            if !plans.isEmpty || !trips.isEmpty {
                Text("Swipe to detach. Detaching keeps the ticket on this device.")
            }
        }
        .trainTrackerRowSurface()
    }

    private func unlink(_ ticketID: UUID, _ owner: JourneyTicketOwner) {
        do {
            switch owner {
            case let .plan(id): try vault.unlink(id: ticketID, planID: id)
            case let .trip(id): try vault.unlink(id: ticketID, tripID: id)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func departureText(_ ticket: LocalJourneyTicket) -> String? {
        guard let clock = ticket.suggestion.departureWallClock ?? ticket.details.departure,
              let date = clock.date(in: TimeZone(secondsFromGMT: 0) ?? .gmt) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: clock.hasTime ? .shortened : .omitted)
        style.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return date.formatted(style) + (clock.hasTime ? " local time" : "")
    }

    private func load(_ ticket: LocalJourneyTicket) async {
        do {
            original = try vault.payload(id: ticket.id)
        } catch {
            loadError = error.localizedDescription
        }
        guard ticket.hasVisualOriginal else {
            isScanning = false
            return
        }
        barcode = await vault.barcode(id: ticket.id)
        isScanning = false
    }
}

/// Tickets attached to a saved journey or train, reachable in one tap, with an explicit attach action.
struct JourneyTicketsSection: View {
    let owner: JourneyTicketOwner

    @Environment(LocalJourneyTicketStore.self) private var vault
    /// Attaching presents from this screen, so it never replaces a sheet the screen is inside.
    @State private var presentsAttach = false

    private var tickets: [LocalJourneyTicket] {
        switch owner {
        case let .plan(id): vault.tickets(forPlan: id)
        case let .trip(id): vault.tickets(forTrip: id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text("Tickets")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ttTextPrimary)
            ForEach(tickets) { ticket in
                NavigationLink {
                    LocalTicketDetailView(ticketID: ticket.id)
                } label: {
                    HStack(spacing: TrainTrackerSpacing.space12) {
                        Image(systemName: ticket.hasVisualOriginal ? "qrcode" : "doc.text")
                            .font(.title3)
                            .foregroundStyle(Color.ttTextOperational)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                            Text("Show Ticket")
                                .font(.headline)
                                .foregroundStyle(Color.ttTextPrimary)
                            Text(ticketSubtitle(ticket))
                                .font(.subheadline)
                                .foregroundStyle(Color.ttTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ttTextSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(LayoutMetrics.cardInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .trainTrackerSurface(radius: TrainTrackerRadius.group)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journeyShowTicket")
            }
            Button {
                presentsAttach = true
            } label: {
                Label(tickets.isEmpty ? "Attach a Ticket" : "Attach Another Ticket", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("journeyAttachTicket")
            .accessibilityHint("Choose a ticket saved on this device, or import one")
        }
        .sheet(isPresented: $presentsAttach) {
            AddJourneyView(attachTo: owner)
                .tint(Color.ttActionTint)
        }
    }

    private func ticketSubtitle(_ ticket: LocalJourneyTicket) -> String {
        let parts = [
            ticket.details.coach.map { "Coach \($0)" },
            ticket.details.seat.map { "Seat \($0)" },
            ticket.details.bookingReference.map { "Booking \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? "Saved on this device" : parts.joined(separator: " · ")
    }
}

/// A scannable barcode on a white quiet zone in both appearances, so a gate reader can scan it
/// in Dark Mode. Shared by local and forwarded ticket screens.
struct TicketBarcodeImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .padding(TrainTrackerSpacing.space16)
            .frame(maxWidth: .infinity)
            .background(Color.white, in: RoundedRectangle(cornerRadius: TrainTrackerRadius.control, style: .continuous))
            .accessibilityLabel("Scannable ticket barcode")
    }
}
