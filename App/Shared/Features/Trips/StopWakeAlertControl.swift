import SwiftUI
import TrainTrackerCore

/// The switch for "Wake me before my stop", with how far ahead and how it will know.
struct StopWakeAlertControl: View {
    let trip: TrainTrip
    /// The stop the rider gets off at.
    let stop: StopTime

    @State private var alerts = StopWakeAlerts.shared
    @State private var isWorking = false
    @State private var problem: String?
    @AppStorage("stopWakeAlerts.lead") private var preferredLead = StopWakeAlerts.defaultLead
    @Environment(\.openURL) private var openURL

    private var alert: StopWakeAlerts.Alert? {
        guard let alert = alerts.alert(for: trip.id), alert.stopID == stop.station.id.rawValue else { return nil }
        return alert
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            ViewThatFits(in: .horizontal) {
                Toggle(isOn: isArmed) {
                    heading.fixedSize(horizontal: true, vertical: true)
                        .padding(.trailing, TrainTrackerSpacing.space12)
                }
                .accessibilityIdentifier("stopWakeAlertToggle")
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                    heading
                    Toggle("Wake alert", isOn: isArmed)
                        .font(.subheadline)
                        .accessibilityLabel("Wake Me Before My Stop")
                        .accessibilityValue("\(stop.station.displayName), \(alert == nil ? "Off" : "On")")
                        .accessibilityIdentifier("stopWakeAlertToggle")
                }
            }
            .tint(Color.ttRouteActive)
            .disabled(isWorking)

            if let alert {
                Picker("How far ahead", selection: Binding(get: { alert.leadMinutes }, set: { arm(lead: $0) })) {
                    ForEach(StopWakeAlerts.leadChoices, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isWorking)

                Text(alert.usesLocation
                     ? "Sounds when you’re about \(alert.leadMinutes) minutes from \(alert.stopName), using your location, and again 2 minutes before the train is due."
                     : "Sounds \(alert.leadMinutes) minutes and 2 minutes before the train is due at \(alert.stopName). Allow location to have the first alert follow the train itself when it runs late.")
                    .font(.footnote)
                    .foregroundStyle(Color.ttTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8) {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(Color.ttTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
        }
        .padding(TrainTrackerSpacing.space16)
        .trainTrackerSurface(radius: TrainTrackerRadius.group)
    }

    private var isArmed: Binding<Bool> {
        Binding(get: { alert != nil }, set: { $0 ? arm(lead: preferredLead) : alerts.disarm(tripID: trip.id) })
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
            Image(systemName: alert == nil ? "alarm" : "alarm.waves.left.and.right.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.ttTextOnBrand)
                .frame(width: 36, height: 36)
                .background(Color.ttBackgroundBrand, in: RoundedRectangle(cornerRadius: TrainTrackerRadius.icon, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text("Wake Me Before My Stop")
                    .font(.headline)
                    .foregroundStyle(Color.ttTextPrimary)
                Text(stop.station.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func arm(lead: Int) {
        preferredLead = lead
        isWorking = true
        problem = nil
        Task {
            let product = trip.product.isEmpty ? trip.operatorName : trip.product
            let result = await alerts.arm(trip: trip, stopID: stop.station.id.rawValue, productName: product, leadMinutes: lead)
            isWorking = false
            switch result {
            case .armed, .superseded: break
            case .notificationsDenied: problem = "Notifications are off for Roundhouse, so it can’t sound an alert."
            case .stopNotAhead: problem = "The train is reported at or past this stop."
            case .timetableElapsed:
                problem = "This stop’s time has passed and nothing reports the train there yet. Allow location to be alerted as you approach it."
            }
        }
    }
}
