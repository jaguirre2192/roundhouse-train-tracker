import Observation
import SwiftUI

/// Remembers which journeys already have a ticket, so a ticket prints once: the first time a
/// newly added journey is shown, and never for the journeys the app opened with.
@MainActor
@Observable
final class TicketPrintQueue {
    static let shared = TicketPrintQueue()

    @ObservationIgnored private var printed: Set<String> = []

    /// The journeys saved before this launch. Their tickets are already printed.
    func seed(_ ids: some Sequence<String>) {
        printed.formUnion(ids)
    }

    func isNew(_ id: String) -> Bool { !printed.contains(id) }

    func markPrinted(_ id: String) {
        printed.insert(id)
    }
}

extension EnvironmentValues {
    /// False while something covers the ticket (the Add Journey sheet, a pushed screen), so the
    /// print waits until it can be seen.
    @Entry var ticketCanPrint = true
}

/// A newly added journey's ticket feeds out of a slot, a line at a time, the way a ticket
/// machine prints one. It happens once per journey. With Reduce Motion the ticket fades in.
struct TicketPrint: ViewModifier {
    let id: String

    @Environment(\.ticketCanPrint) private var canPrint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How much of the ticket is out of the slot, from 0 to 1.
    @State private var fed: CGFloat
    @State private var isPrinting = false
    @State private var feeds = 0
    @State private var finished = 0

    private static let steps = 7

    init(id: String) {
        self.id = id
        _fed = State(initialValue: TicketPrintQueue.shared.isNew(id) ? 0 : 1)
    }

    func body(content: Content) -> some View {
        let fed = fed
        content
            .visualEffect { [reduceMotion] ticket, proxy in
                ticket.offset(y: reduceMotion ? 0 : -(proxy.size.height + 12) * (1 - fed))
            }
            .opacity(reduceMotion ? fed : 1)
            // The slot's edge: nothing shows above it while the ticket feeds. Around the other
            // sides, and above once it is out, the mask leaves room for the ticket's shadow.
            .mask {
                Rectangle()
                    .padding(.horizontal, -40)
                    .padding(.bottom, -60)
                    .padding(.top, fed < 1 ? 0 : -40)
            }
            .overlay(alignment: .top) {
                if isPrinting, !reduceMotion {
                    Capsule()
                        .fill(Color.ttBackgroundBrand)
                        .frame(height: 5)
                        .padding(.horizontal, -TrainTrackerSpacing.space4)
                        .shadow(color: Color.ttBackgroundBrand.opacity(0.35), radius: 4, y: 2)
                        .offset(y: -2.5)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .preferredSensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: feeds)
            .preferredSensoryFeedback(.success, trigger: finished)
            .task(id: canPrint) { await printIfNew() }
    }

    private func printIfNew() async {
        guard canPrint, TicketPrintQueue.shared.isNew(id) else {
            // Shown before: make sure nothing is left half out.
            if !TicketPrintQueue.shared.isNew(id) { fed = 1 }
            return
        }
        TicketPrintQueue.shared.markPrinted(id)
        // Let the sheet that added the journey get out of the way first.
        try? await Task.sleep(for: .milliseconds(450))
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.35)) { fed = 1 }
            finished += 1
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { isPrinting = true }
        for step in 1...Self.steps {
            withAnimation(.easeOut(duration: 0.11)) { fed = CGFloat(step) / CGFloat(Self.steps) }
            feeds += 1
            try? await Task.sleep(for: .milliseconds(150))
        }
        fed = 1
        finished += 1
        withAnimation(.easeOut(duration: 0.3)) { isPrinting = false }
    }
}

extension View {
    /// Prints this ticket the first time a newly added journey is shown.
    func printsTicket(id: String) -> some View {
        modifier(TicketPrint(id: id)).id("ticket-print-\(id)")
    }
}
