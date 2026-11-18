import SwiftUI
import UIKit

/// Forwarding a booking email to a private address. Other import sources live in Add Journey,
/// which pushes this screen inside its own navigation stack.
struct ForwardTicketIntakeView: View {
    @Environment(ForwardingStore.self) private var forwarding
    @State private var presentsAccountGate = false
    @State private var copiedAddress = false
    @State private var showsRotateConfirmation = false
    @State private var showsDisableConfirmation = false

    var body: some View {
        Form {
            Section {
                forwardingContent
            } header: {
                Text("Forward Ticket")
            } footer: {
                if forwarding.state == .active {
                    Text("Forward booking confirmations to your private address. You can review the tickets in My Trips.")
                }
            }
            .trainTrackerRowSurface()
        }
        .formStyle(.grouped)
        .trainTrackerListCanvas()
        .navigationTitle("Forward a Booking Email")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $presentsAccountGate) {
            AccountGateView()
        }
    }

    @ViewBuilder
    private var forwardingContent: some View {
        switch forwarding.state {
        case .signInRequired:
            Text("Sign in to create a private forwarding address for your tickets.")
                .foregroundStyle(Color.ttTextSecondary)
            Button {
                presentsAccountGate = true
            } label: {
                Label("Sign In or Create Account", systemImage: "person.crop.circle.badge.plus")
            }
            .accessibilityHint("Opens account sign in without leaving the ticket import options")
        case .loading:
            HStack {
                ProgressView()
                Text("Checking your forwarding address…")
            }
            .foregroundStyle(Color.ttTextSecondary)
        case .inactive:
            Button {
                Task { await forwarding.createAddress() }
            } label: {
                Label("Create a Forwarding Address", systemImage: "envelope.badge.shield.half.filled")
            }
            .disabled(forwarding.isWorking)
        case .active:
            if let address = forwarding.address {
                LabeledContent("Forwarding address", value: address)
                Button {
                    UIPasteboard.general.string = address
                    copiedAddress = true
                } label: {
                    Label(copiedAddress ? "Copied" : "Copy Address", systemImage: "doc.on.doc")
                }
            } else {
                Label("Forwarding is active", systemImage: "checkmark.seal")
                    .foregroundStyle(Color.ttTextSecondary)
                Text("Rotate to reveal your address again.")
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            Button {
                showsRotateConfirmation = true
            } label: {
                Label("Rotate Address", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(forwarding.isWorking)
            .confirmationDialog(
                "Rotate your forwarding address?",
                isPresented: $showsRotateConfirmation,
                titleVisibility: .visible
            ) {
                Button("Rotate", role: .destructive) { Task { await forwarding.rotateAddress() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your current address will stop accepting tickets immediately. Update anywhere you've shared it.")
            }
            Button(role: .destructive) {
                showsDisableConfirmation = true
            } label: {
                Label("Disable Forwarding", systemImage: "xmark.circle")
            }
            .disabled(forwarding.isWorking)
            .confirmationDialog(
                "Disable ticket forwarding?",
                isPresented: $showsDisableConfirmation,
                titleVisibility: .visible
            ) {
                Button("Disable", role: .destructive) { Task { await forwarding.disable() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your forwarding address will stop accepting new tickets. Tickets you've already received stay in My Trips.")
            }
        }
        if let errorMessage = forwarding.errorMessage ?? forwarding.refreshIssue {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(Color.ttStatusDelayed)
        }
    }
}
