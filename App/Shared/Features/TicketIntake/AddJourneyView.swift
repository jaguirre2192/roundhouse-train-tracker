import PhotosUI
import SwiftUI
import TrainTrackerCore
import UIKit
import UniformTypeIdentifiers

/// One place to add a journey from a ticket photo, screenshot, PDF, pasted text, Calendar,
/// forwarded email or the Share sheet. Tickets are read and saved on this device first.
struct AddJourneyView: View {
    /// When set, a chosen or imported ticket is attached to this journey or train directly.
    let attachTo: JourneyTicketOwner?
    /// Called instead of presenting from the app root, for callers that own their own sheet.
    var onReview: ((JourneyIntakeModel.ReviewRequest) -> Void)?

    @Environment(JourneyIntakeModel.self) private var intake
    @Environment(LocalJourneyTicketStore.self) private var vault
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var photoItem: PhotosPickerItem?
    @State private var showsFileImporter = false
    @State private var showsPaste = false
    @State private var pastedText = ""
    @State private var presentsCalendar = false
    @State private var isImporting = false
    @State private var importRecovery = AddJourneyImportRecovery()
    /// False when a screen (a journey, a train or ticket purchase) presents this sheet itself.
    @State private var isRootPresented = true
    /// A Calendar choice waits until its sheet has closed before another sheet is presented.
    @State private var pendingCalendarReview: (suggestion: TicketRouteSuggestion, isEdited: Bool)?

    init(attachTo: JourneyTicketOwner? = nil, onReview: ((JourneyIntakeModel.ReviewRequest) -> Void)? = nil) {
        self.attachTo = attachTo
        self.onReview = onReview
    }

    var body: some View {
        NavigationStack {
            Form {
                if attachTo == nil {
                    Section {
                        AddJourneySearchAction {
                            close()
                            navigation.open(.stations)
                        }
                    }
                    .trainTrackerFormActionRow()
                }
                ticketSources
                importStatus
                if attachTo != nil {
                    savedTicketsToAttach
                } else {
                    unfinished
                    otherSources
                    savedTickets
                }
            }
            .formStyle(.grouped)
            .trainTrackerListCanvas()
            .navigationTitle(attachTo == nil ? "Add Journey" : "Attach a Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
            }
            .disabled(isImporting)
            .onAppear {
                if case .addJourney = intake.presentation {
                    isRootPresented = true
                } else {
                    isRootPresented = false
                    intake.beginLocalPresentation()
                }
            }
            .onDisappear {
                if !isRootPresented { intake.endLocalPresentation() }
                if intake.errorMessage != nil, !isRootPresented { intake.dismissError() }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task { await importPhoto(item) }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: Self.fileTypes,
                allowsMultipleSelection: false
            ) { result in
                Task { await importFile(result) }
            }
            .sheet(isPresented: $showsPaste) { pasteSheet }
            .sheet(isPresented: $presentsCalendar, onDismiss: {
                guard let pending = pendingCalendarReview else { return }
                pendingCalendarReview = nil
                route(intake.reviewRequest(for: pending.suggestion, isEdited: pending.isEdited))
            }) {
                CalendarImportView { suggestion, isEdited in
                    pendingCalendarReview = (suggestion, isEdited)
                    presentsCalendar = false
                }
            }
        }
        .environment(\.journeyReviewRouter, onReview.map { handler in JourneyReviewRouter(route: handler) })
    }

    // MARK: - Sections

    private var ticketSources: some View {
        Section {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                Label("Photo or Screenshot", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("addJourneyPhoto")
            Button { showsFileImporter = true } label: {
                Label("PDF or File", systemImage: "doc.richtext")
            }
            .accessibilityIdentifier("addJourneyFile")
            Button { showsPaste = true } label: {
                Label("Paste Ticket Text", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("addJourneyPaste")
#if DEBUG
            if FrictionlessIntakeQA.documentFixturesEnabled(arguments: ProcessInfo.processInfo.arguments) {
                Button("Load QA Photo Fixture") {
                    Task { await importData(FrictionlessIntakeQA.ticketImageData(), kind: .image, filename: "QA Ticket.png") }
                }
                .accessibilityIdentifier("addJourneyQAImageFixture")
                Button("Load QA PDF Fixture") {
                    Task { await importData(FrictionlessIntakeQA.ticketPDFData(), kind: .pdf, filename: "QA Ticket.pdf") }
                }
                .accessibilityIdentifier("addJourneyQAPDFFixture")
            }
#endif
        } header: {
            Text("From a Ticket")
        } footer: {
            Text(attachTo == nil
                 ? "Tickets are read and saved on this device for offline use. A complete ticket uses only its stations and departure time to find matching trains automatically. The original ticket stays on this device."
                 : "Tickets are read and saved on this device for offline use. Attaching a ticket does not send its contents to the train search.")
                .accessibilityIdentifier("addJourneyImportExplanation")
        }
        .trainTrackerRowSurface()
    }

    @ViewBuilder
    private var importStatus: some View {
        if isImporting {
            Section {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    ProgressView()
                    Text("Reading your ticket on this device…")
                }
                .accessibilityElement(children: .combine)
            }
            .trainTrackerRowSurface()
        } else if let message = importRecovery.errorMessage ?? intake.errorMessage {
            Section {
                TrainTrackerNotice(message, systemImage: "externaldrive.badge.exclamationmark") {
                    if importRecovery.retryPayload != nil {
                        Button("Try Again") { Task { await retry() } }
                            .accessibilityIdentifier("addJourneyRetry")
                    } else if importRecovery.errorMessage == nil {
                        Button("OK") { intake.dismissError() }
                    }
                }
            }
            .trainTrackerFormActionRow()
        }
        if let loadError = vault.loadError {
            Section {
                TrainTrackerNotice("Saved tickets need attention", message: loadError, systemImage: "externaldrive.badge.exclamationmark") {
                    Button("Load Saved Tickets Again") { vault.reload() }
                }
            }
            .trainTrackerFormActionRow()
        }
    }

    @ViewBuilder
    private var unfinished: some View {
        let tickets = vault.draftTickets
        let reviews = vault.reviews
        if !tickets.isEmpty || !reviews.isEmpty {
            Section {
                ForEach(tickets) { ticket in
                    Button {
                        route(JourneyIntakeModel.ReviewRequest(suggestion: ticket.suggestion, ticketID: ticket.id, vault: vault))
                    } label: {
                        UnfinishedImportRow(title: ticket.title, subtitle: ticket.kindTitle, date: ticket.updatedAt,
                                            actionLabel: "Continue Review")
                    }
                    .accessibilityHint("Continues reviewing this ticket")
                }
                ForEach(reviews) { review in
                    Button {
                        route(intake.reviewRequest(for: review))
                    } label: {
                        UnfinishedImportRow(title: reviewTitle(review), subtitle: review.sourceDescription, date: nil,
                                            actionLabel: "Continue Review")
                    }
                    .accessibilityHint("Continues this review")
                }
            } header: {
                Text("Unfinished")
            } footer: {
                Text("Your edits are saved. Pick up where you left off.")
            }
            .trainTrackerRowSurface()
        }
    }

    @ViewBuilder
    private var savedTicketsToAttach: some View {
        let available = vault.tickets.filter { ticket in
            switch attachTo {
            case let .plan(id): !ticket.linkedPlanIDs.contains(id)
            case let .trip(id): !ticket.linkedTripIDs.contains(id)
            case nil: false
            }
        }
        if !available.isEmpty {
            Section("Saved on This Device") {
                ForEach(available) { ticket in
                    Button {
                        attach(ticket)
                    } label: {
                        UnfinishedImportRow(title: ticket.title, subtitle: ticket.kindTitle, date: ticket.createdAt)
                    }
                    .accessibilityHint("Attaches this ticket")
                }
            }
            .trainTrackerRowSurface()
        }
    }

    @ViewBuilder
    private var savedTickets: some View {
        let kept = vault.tickets.filter { !$0.isDraft }.sorted { $0.createdAt > $1.createdAt }
        if !kept.isEmpty {
            Section {
                ForEach(kept) { ticket in
                    NavigationLink {
                        LocalTicketDetailView(ticketID: ticket.id)
                    } label: {
                        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                            Text(ticket.title)
                                .foregroundStyle(Color.ttTextPrimary)
                            Text(ticket.isLinked ? "Attached to a journey" : "Not attached")
                                .font(.subheadline)
                                .foregroundStyle(Color.ttTextSecondary)
                        }
                    }
                }
            } header: {
                Text("Saved on This Device")
            } footer: {
                Text("Original tickets stay available offline until you delete them.")
            }
            .trainTrackerRowSurface()
        }
    }

    private var otherSources: some View {
        Section {
            Button { presentsCalendar = true } label: {
                Label("Import from Calendar", systemImage: "calendar")
            }
            .accessibilityHint("Reads calendar events on this device when you choose to import")
            NavigationLink {
                ForwardTicketIntakeView()
            } label: {
                Label("Forward a Booking Email", systemImage: "envelope")
            }
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Label("Share to Roundhouse", systemImage: "square.and.arrow.up")
                Text("In Mail, Files or Photos, tap Share and choose Roundhouse.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("More Ways to Add")
        }
        .trainTrackerRowSurface()
    }

    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedText)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Ticket text")
                        .accessibilityIdentifier("addJourneyPasteText")
                    PasteButton(payloadType: String.self) { strings in
                        pastedText = strings.joined(separator: "\n")
                    }
                } footer: {
                    Text("Paste the booking confirmation or ticket details. The text is read on this device.")
                }
                .trainTrackerRowSurface()
            }
            .formStyle(.grouped)
            .trainTrackerListCanvas()
            .navigationTitle("Paste Ticket Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        let text = pastedText
                        showsPaste = false
                        pastedText = ""
                        Task { await importData(Data(text.utf8), kind: .text, filename: nil) }
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("addJourneyPasteContinue")
                }
            }
        }
    }

    // MARK: - Import

    private static let fileTypes: [UTType] = [.pdf, .image, .plainText, UTType(filenameExtension: "eml")].compactMap { $0 }

    private func importPhoto(_ item: PhotosPickerItem) async {
        importRecovery.beginImport()
        isImporting = true
        defer { isImporting = false }
        do {
            guard var data = try await item.loadTransferable(type: Data.self) else {
                importRecovery.fail("That photo couldn't be read. Choose it again.")
                return
            }
            if !ShareImportLimits.isSizeAllowed(data.count), let reduced = Self.reducedImage(data) {
                data = reduced
            }
            await importData(data, kind: .image, filename: nil)
        } catch {
            importRecovery.fail("That photo couldn't be read. Choose it again.")
        }
    }

    private func importFile(_ result: Result<[URL], Error>) async {
        importRecovery.beginImport()
        guard case let .success(urls) = result, let url = urls.first else {
            if case .failure = result { importRecovery.fail("That file couldn't be opened. Choose it again.") }
            return
        }
        isImporting = true
        defer { isImporting = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, let kind = ShareImportLimits.kind(forTypeIdentifier: type.identifier) else {
            importRecovery.fail("Choose a PDF, image, text or email file.")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            await importData(data, kind: kind, filename: url.lastPathComponent)
        } catch {
            importRecovery.fail("That file couldn't be opened. Choose it again.")
        }
    }

    private func importData(_ data: Data, kind: ShareManifest.Kind, filename: String?) async {
        isImporting = true
        importRecovery.beginImport()
        defer { isImporting = false }
        do {
            let result = try await vault.importPayload(data, kind: kind, filename: filename)
            if let attachTo {
                intake.attach(ticketID: result.ticket.id, to: attachTo)
                close()
                return
            }
            if !result.isNew, !result.ticket.isDraft,
               let plan = planLibrary.plans.first(where: { result.ticket.linkedPlanIDs.contains($0.id) }) {
                // The same ticket was imported before and already belongs to a saved journey.
                close()
                navigation.openJourneyPlan(id: plan.id)
                return
            }
            if !result.ticket.isDraft {
                do { try vault.reopenForReview(id: result.ticket.id) } catch {
                    importRecovery.fail(error.localizedDescription)
                    return
                }
            }
            let ticket = vault.ticket(id: result.ticket.id) ?? result.ticket
            route(JourneyIntakeModel.ReviewRequest(suggestion: ticket.suggestion, ticketID: ticket.id, vault: vault))
        } catch {
            let retryPayload = (error as? LocalJourneyTicketStore.StoreError) == .unavailable
                ? AddJourneyImportRecovery.Payload(data: data, kind: kind, filename: filename)
                : nil
            importRecovery.fail(error.localizedDescription, retryPayload: retryPayload)
        }
    }

    private func retry() async {
        guard let pending = importRecovery.retryPayload else { return }
        await importData(pending.data, kind: pending.kind, filename: pending.filename)
    }

    private func attach(_ ticket: LocalJourneyTicket) {
        guard let attachTo else { return }
        intake.attach(ticketID: ticket.id, to: attachTo)
        close()
    }

    private func route(_ request: JourneyIntakeModel.ReviewRequest) {
        if let onReview {
            onReview(request)
        } else {
            intake.presentReview(request)
        }
    }

    /// Dismissal always goes through SwiftUI, so a root sheet clears its presentation binding
    /// and a screen-owned sheet closes only itself.
    private func close() {
        dismiss()
    }

    private func reviewTitle(_ review: TicketRouteSuggestion) -> String {
        if let origin = review.originGuess, let destination = review.destinationGuess { return "\(origin) → \(destination)" }
        return review.subtitle ?? "Journey to review"
    }

    private static func reducedImage(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 3_000 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.85)
    }
}

/// A retry belongs only to the import that failed to save. Choosing a replacement clears it
/// before its contents are read, so an unreadable replacement cannot retry the previous ticket.
struct AddJourneyImportRecovery {
    struct Payload {
        let data: Data
        let kind: ShareManifest.Kind
        let filename: String?
    }

    private(set) var errorMessage: String?
    private(set) var retryPayload: Payload?

    mutating func beginImport() {
        errorMessage = nil
        retryPayload = nil
    }

    mutating func fail(_ message: String, retryPayload: Payload? = nil) {
        errorMessage = message
        self.retryPayload = retryPayload
    }
}

struct UnfinishedImportRow: View {
    let title: String
    let subtitle: String
    let date: Date?
    var actionLabel: String? = nil

    var body: some View {
        HStack(spacing: TrainTrackerSpacing.space12) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.ttTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text([subtitle, date.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                if let actionLabel {
                    Text(actionLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ttTextBrand)
                        .padding(.top, TrainTrackerSpacing.space4)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ttTextSecondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Lets screens pushed inside a caller-owned Add Journey sheet hand reviews back to that caller.
struct JourneyReviewRouter {
    let route: (JourneyIntakeModel.ReviewRequest) -> Void
}

extension EnvironmentValues {
    @Entry var journeyReviewRouter: JourneyReviewRouter?
}
