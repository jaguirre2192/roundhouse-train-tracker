import SwiftUI

struct TrainAlertSettingsSection: View {
    @Environment(TripLibrary.self) private var library
    @AppStorage(AlertPreference.delayThreshold) private var minutesLate = 5
    @AppStorage(AlertPreference.platformChanges) private var platformChanges = true
    @AppStorage(AlertPreference.cancellations) private var cancellations = true
    @AppStorage(AlertPreference.disruptions) private var disruptions = true
    @AppStorage(TrainTrackerPreference.autoLockScreen) private var autoLockScreen = true

    var body: some View {
        Section {
            Picker(selection: $minutesLate) {
                ForEach(AlertPreference.delayThresholdChoices, id: \.self) { Text("\($0) min").tag($0) }
            } label: {
                Label("Late By", systemImage: "clock.badge.exclamationmark")
            }
            Toggle(isOn: $platformChanges) { Label("Platform and Track Changes", systemImage: "arrow.triangle.branch") }
            Toggle(isOn: $cancellations) { Label("Cancellations", systemImage: "xmark.octagon") }
            Toggle(isOn: $disruptions) { Label("Service Disruptions", systemImage: "exclamationmark.triangle") }
            Toggle(isOn: $autoLockScreen) {
                Label("Automatic Live Activities", systemImage: "platter.filled.bottom.iphone")
            }
            .accessibilityIdentifier("settings.autoLiveActivity")
        } header: {
            Text("Alert Me About")
        } footer: {
            Text("A late alert is sent the first time a tracked train reaches your threshold. Automatic Live Activities put your train on the Lock Screen when you open Roundhouse within an hour of departure.")
                .foregroundStyle(Color.ttTextPrimary)
        }
        .labelStyle(SettingsTileLabelStyle())
        .tint(Color.ttActionTint)
        .trainTrackerRowSurface()
        .onChange(of: [minutesLate, platformChanges ? 1 : 0, cancellations ? 1 : 0, disruptions ? 1 : 0]) {
            library.resumePushWatches()
        }
    }

}
