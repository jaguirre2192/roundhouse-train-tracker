import SwiftUI

/// Opens the original local artifact immediately, including PDF, image and text bookings.
struct PlatformBoardOriginal: View {
    let ticket: LocalJourneyTicket
    @Environment(LocalJourneyTicketStore.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let data {
                    if ticket.hasVisualOriginal {
                        if ticket.kind == .pdf {
                            TicketAttachmentPreview(data: data, mimeType: ticket.mimeType)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("platformOriginalDocument")
                        } else {
                            ScrollView { TicketAttachmentPreview(data: data, mimeType: ticket.mimeType) }
                        }
                    } else {
                        ScrollView {
                            Text(String(decoding: data, as: UTF8.self)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(LayoutMetrics.pageInset)
                        }
                    }
                } else if let error {
                    ContentUnavailableView("Ticket unavailable", systemImage: "ticket", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Original Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: ticket.id) {
                do { data = try vault.payload(id: ticket.id) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
