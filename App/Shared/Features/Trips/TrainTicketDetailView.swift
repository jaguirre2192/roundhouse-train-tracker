import SwiftUI
import UIKit

struct TrainTicketDetailView<Ticket: TicketSummaryDisplaying>: View {
    @Environment(JourneyIntakeModel.self) private var intake
    @Environment(LocalJourneyTicketStore.self) private var vault
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    let artifactSource: any TicketArtifactSource
    /// Returns an error message when deletion failed, or nil when the ticket was deleted.
    var onDelete: (() async -> String?)?

    @State private var attachment: Data?
    @State private var attachmentMimeType: String?
    @State private var barcode: Data?
    @State private var loadingError: String?
    @State private var isDeleting = false
    @State private var showsDeleteConfirmation = false
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var deleteError: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ticket.displayTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.ttTextPrimary)
                    if let route = ticket.route {
                        Text(route)
                            .font(.subheadline)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .railTicketStyle()
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if let origin = ticket.originName, let destination = ticket.destinationName {
                Section {
                    Button {
                        intake.review(suggestion: reviewSuggestion(origin: origin, destination: destination))
                    } label: {
                        Label("Find & Track Journey", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .trainTrackerPrimaryAction()
                    .accessibilityHint("Reviews this ticket's route and departure time before searching")
                }
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Operator", value: ticket.operatorName ?? "Not identified")
                if let trainNumber = ticket.trainNumber { LabeledContent("Train", value: trainNumber) }
                if let route = ticket.route { LabeledContent("Journey", value: route) }
                if let passenger = ticket.passengerName { LabeledContent("Passenger", value: passenger) }
                if let coach = ticket.coach { LabeledContent("Coach", value: coach) }
                if let seat = ticket.seat { LabeledContent("Seat", value: seat) }
                if let booking = ticket.bookingReference { LabeledContent("Booking", value: booking) }
            }
            .trainTrackerRowSurface()

            if ticket.hasArtifact {
                Section("Ticket") {
                    if let barcode, let image = UIImage(data: barcode) {
                        TicketBarcodeImage(image: image)
                    } else if let attachment, let attachmentMimeType {
                        TicketAttachmentPreview(data: attachment, mimeType: attachmentMimeType)
                    } else if let loadingError {
                        ContentUnavailableView("Ticket unavailable", systemImage: "qrcode", description: Text(loadingError))
                    } else {
                        HStack { Spacer(); ProgressView("Finding barcode…"); Spacer() }
                    }
                    if loadingError == nil, barcode != nil || attachment != nil {
                        saveToDeviceRow
                    }
                }
                .trainTrackerRowSurface()
            }

            Section("Source") {
                Text(ticket.sourceLabel)
                Text(ticket.subject)
                Text("Ticket contents are requested only when you open this screen and are not added to the public trip-share link.")
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            .trainTrackerRowSurface()

            if onDelete != nil {
                Section {
                    if let deleteError {
                        Label(deleteError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.ttStatusDelayed)
                    }
                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        if isDeleting {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("Delete Ticket")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isDeleting)
                }
                .trainTrackerRowSurface()
            }
        }
        .trainTrackerListCanvas()
        .navigationTitle("Ticket")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTicket() }
        .confirmationDialog(
            "Delete this ticket?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from Roundhouse. It can't be undone.")
        }
    }

    @ViewBuilder
    private var saveToDeviceRow: some View {
        let digest = attachment.map(LocalJourneyTicketStore.digest)
        if let digest, let saved = vault.tickets.first(where: { $0.digest == digest }) {
            NavigationLink {
                LocalTicketDetailView(ticketID: saved.id)
            } label: {
                Label("Saved on this device", systemImage: "lock.iphone")
            }
        } else {
            Button {
                Task { await saveToDevice() }
            } label: {
                Label(isSaving ? "Saving…" : "Save to This Device", systemImage: "square.and.arrow.down")
            }
            .disabled(isSaving)
            .accessibilityHint("Keeps the original ticket available offline and lets you attach it to a journey")
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(Color.ttStatusDelayed)
            }
        }
    }

    /// Fetches the original when only a cached barcode was shown, then saves it locally.
    private func saveToDevice() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            if attachment == nil {
                let (data, mimeType) = try await artifactSource.artifactData(ticketID: ticket.id)
                attachment = data
                attachmentMimeType = mimeType
            }
            guard let data = attachment else { return }
            let kind: ShareManifest.Kind = attachmentMimeType == "application/pdf" ? .pdf : .image
            _ = try await vault.importPayload(data, kind: kind, filename: ticket.displayTitle)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Forwarded and inbox tickets use the same review as every other import.
    private func reviewSuggestion(origin: String, destination: String) -> TicketRouteSuggestion {
        let value = ticket.departureTime
        let clock = value.flatMap { TicketWallClock(requestValue: $0) }
        let instant = clock == nil ? value.flatMap { ISO8601DateFormatter().date(from: $0) } : nil
        let zone = TicketTextDetails.stationTimeZone(origin)
        return TicketRouteSuggestion(
            id: Self.stableReviewID(ticket.id),
            sourceDescription: ticket.sourceLabel,
            subtitle: ticket.subject,
            originGuess: origin,
            destinationGuess: destination,
            trainNumberGuess: ticket.trainNumber,
            departureDate: instant,
            requiresDepartureTime: clock.map { !$0.hasTime } ?? false,
            departureTimeZoneIdentifier: instant == nil ? nil : zone,
            departureWallClock: clock
        )
    }

    /// Reopening the same forwarded ticket resumes one unfinished review instead of adding another.
    private static func stableReviewID(_ ticketID: String) -> UUID {
        JourneyDraftIdentity.stableID(seed: UUID(uuidString: "6F1D2A4E-1C55-4C7B-9E0B-3D9E2A6A5F10")!, fingerprint: ticketID)
    }

    private func loadTicket() async {
        guard ticket.hasArtifact, attachment == nil else { return }
        do {
            if let cached = await artifactSource.cachedBarcode(ticketID: ticket.id) {
                barcode = cached
                return
            }
            let (data, mimeType) = try await artifactSource.artifactData(ticketID: ticket.id)
            attachment = data
            attachmentMimeType = mimeType
            barcode = try await Task.detached {
                try TicketBarcodeScanner.croppedBarcode(from: data, mimeType: mimeType)
            }.value
            if let barcode { await artifactSource.saveBarcode(barcode, ticketID: ticket.id) }
        } catch {
            loadingError = error.localizedDescription
        }
    }

    private func performDelete() async {
        guard let onDelete, !isDeleting else { return }
        isDeleting = true
        deleteError = await onDelete()
        isDeleting = false
        if deleteError == nil { dismiss() }
    }
}
