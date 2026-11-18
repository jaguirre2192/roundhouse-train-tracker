import SwiftUI
import TrainTrackerCore

/// "Wake Me Before My Stop" from the wrist. The iPhone owns the alert, so the switch shows
/// only what the phone has confirmed: turning it on asks the phone, and until the phone
/// answers the switch stays off and says it is asking.
struct WatchWakeControl: View {
    @Environment(WatchStore.self) private var store
    let train: WidgetTripSnapshot.Train
    let state: WatchStore.WakeState

    @AppStorage("stopWakeAlerts.lead") private var preferredLead = WatchWakeRequest.defaultLead

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                WatchTrainName(name: train.serviceName)
                Text("Wake Me Before My Stop")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: Binding(
                get: { state.armedLead != nil },
                set: { store.requestWake(for: train, lead: $0 ? preferredLead : nil) }
            )) {
                Text(stopName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color(.routeOnInk))
            .disabled(isPending)
            .accessibilityLabel("Wake Me Before My Stop, \(stopName)")

            if let lead = shownLead {
                ViewThatFits(in: .horizontal) {
                    leadChoices(selected: lead, showsUnit: true)
                    leadChoices(selected: lead, showsUnit: false)
                }
                .disabled(isPending)
            }

            if let message {
                HStack(alignment: .center, spacing: 8) {
                    if case .asking = state {
                        ProgressView()
                            .controlSize(.small)
                            .fixedSize()
                    }
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .waiting = state {
                Button("Cancel Request") { store.cancelWakeRequest(for: train.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    /// Three short choices side by side, as on the phone: "5 min", "10 min", "15 min". Where
    /// that is too wide, the numbers alone with the unit after them.
    private func leadChoices(selected: Int, showsUnit: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(WatchWakeRequest.leadChoices, id: \.self) { minutes in
                Button {
                    preferredLead = minutes
                    if minutes != selected { store.requestWake(for: train, lead: minutes) }
                } label: {
                    // The chosen lead is the filled one, so it reads without relying on hue.
                    Text(showsUnit ? "\(minutes) min" : "\(minutes)")
                        .font(.footnote.weight(.semibold))
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .foregroundStyle(minutes == selected ? .black : .primary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            minutes == selected ? AnyShapeStyle(Color(.routeOnInk)) : AnyShapeStyle(.white.opacity(0.14)),
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(minutes) minutes before")
                .accessibilityAddTraits(minutes == selected ? .isSelected : [])
            }
            if !showsUnit {
                Text("min")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }

    private var stopName: String {
        train.alighting?.name ?? train.stops.last?.name ?? "Your stop"
    }

    private var isPending: Bool {
        switch state {
        case .asking, .waiting: true
        case .off, .armed, .problem: false
        }
    }

    /// The lead to show selected: the confirmed one, or the one being asked for.
    private var shownLead: Int? {
        switch state {
        case let .armed(lead): lead
        case let .asking(lead), let .waiting(lead): lead
        case .off, .problem: nil
        }
    }

    private var message: String? {
        switch state {
        case .off:
            nil
        case .armed:
            "Your iPhone sounds the alert. It shows here too."
        case .asking:
            "Asking iPhone…"
        case .waiting:
            "Waiting for iPhone. It will answer when it’s in reach."
        case let .problem(outcome):
            switch outcome {
            case .notificationsDenied: "Allow notifications on iPhone"
            case .stopNotAhead: "The train has already reached this stop."
            case .tripNotFound: "This train is no longer on your iPhone."
            case .needsPhone: "Open Roundhouse on iPhone to finish."
            case .armed, .disarmed: nil
            }
        }
    }
}
