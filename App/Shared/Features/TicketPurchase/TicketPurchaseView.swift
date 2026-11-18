import SwiftUI
import TrainTrackerCore
import UIKit

struct TicketPurchaseView: View {
    @Environment(TicketPurchaseStore.self) private var purchases
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(JourneyIntakeModel.self) private var intake
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let journey: TicketPurchaseJourney
    var isResuming = false
    @State private var showsBrowser = false
    @State private var showsIntake = false
    @State private var holdsIntakePresentation = false
    @State private var returned = false
    @State private var externalBrowserOpened = false
    @State private var errorMessage: String?
    @State private var browserFailed = false
    @State private var copied = false
    @State private var importRequest: JourneyIntakeModel.ReviewRequest?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                    retailerSection(canSearch: journey.canSearch(at: context.date))
                    TicketPurchaseItinerary(journey: journey)
                    Button {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: journey.summary]],
                            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(600)])
                        copied = true
                    } label: {
                        Label(copied ? "Journey Details Copied" : "Copy Journey Details", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("Copies scheduled station-local times and train numbers. No ticket is reserved.")
                    importSection
                }
                .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
                .padding(LayoutMetrics.pageInset)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.ttBackgroundCanvas)
        .navigationTitle("Tickets")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showsBrowser, onDismiss: { returned = true }) {
            TicketRetailerBrowser(url: browserURL, onInitialLoadFailed: {
                browserFailed = true
                errorMessage = "Omio couldn’t load. Your journey details are saved. Try again or open the search in Safari."
                showsBrowser = false
            }, onDone: { showsBrowser = false })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showsIntake, onDismiss: {
            guard let request = importRequest else { return }
            importRequest = nil
            dismiss()
            intake.presentReview(request)
        }) {
            AddJourneyView { request in
                importRequest = request
                showsIntake = false
            }
        }
        .onChange(of: showsBrowser || showsIntake) { _, presenting in
            // Shared tickets that arrive while this screen owns a modal wait for it to close.
            if presenting, !holdsIntakePresentation {
                holdsIntakePresentation = true
                intake.beginLocalPresentation()
            } else if !presenting, holdsIntakePresentation {
                holdsIntakePresentation = false
                intake.endLocalPresentation()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, externalBrowserOpened {
                returned = true
                externalBrowserOpened = false
            }
        }
    }

    private var browserURL: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-TicketRetailerFailurePreview") {
            return URL(string: "https://ticket-retailer.invalid")!
        }
        #endif
        return journey.retailerURL
    }

    private func retailerSection(canSearch: Bool) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text(returned || isResuming ? "Your journey is still here" : "Find your ticket on Omio")
                .font(.title2.weight(.semibold))
            Text(returned || isResuming
                 ? "Check your Omio confirmation before traveling, then import your ticket below. If you search again, select the matching stations, dates and trains; nothing is filled in automatically."
                 : "Search and pay on Omio. Your stations, dates and trains won’t be filled in automatically; use the scheduled details below to select the matching journey.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttStatusDelayed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ticketPurchaseError")
            }
            if !canSearch {
                Text("The scheduled departure has passed. Find an upcoming journey to check tickets.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            Button(action: beginSearch) {
                Label(browserFailed ? "Try Omio Again" : "Continue to Omio", systemImage: "arrow.up.right")
                    .trainTrackerFullWidthAction()
            }
            .trainTrackerPrimaryAction()
            .controlSize(.large)
            .disabled(!canSearch)
            .accessibilityIdentifier("continueToTicketRetailer")
            .accessibilityHint("Saves these journey details and opens Omio’s general train search. You select your dates, passengers and matching service there.")
            if browserFailed {
                Button(action: beginExternalSearch) {
                    Label("Open in Safari", systemImage: "safari")
                        .trainTrackerFullWidthAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canSearch)
            }
            Text("Choose passengers, class and discounts on Omio. Availability and fares may differ. Omio handles payment, ticket delivery, changes and refunds.")
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text("Already bought your ticket?")
                .font(.headline)
            Text("Add it from a photo, PDF, pasted text, its calendar event or a forwarded confirmation.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
            Button { showsIntake = true } label: {
                Label("Import a Ticket", systemImage: "ticket")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("importPurchasedTicket")
        }
    }

    private func prepareSearch() -> Bool {
        do {
            try purchases.prepare(journey)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? TicketPurchaseStore.StorageError)?.localizedDescription
                ?? "Your ticket search couldn’t be saved. Free some device storage and try again. Your selected journey is still here."
            return false
        }
    }

    private func beginSearch() {
        guard prepareSearch() else { return }
        browserFailed = false
        showsBrowser = true
    }

    private func beginExternalSearch() {
        guard prepareSearch() else { return }
        openURL(journey.retailerURL) { accepted in
            if accepted { externalBrowserOpened = true }
            else { errorMessage = "Safari couldn’t open Omio. Try the in-app search again." }
        }
    }
}
