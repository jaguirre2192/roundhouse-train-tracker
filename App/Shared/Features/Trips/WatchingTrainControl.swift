import SwiftUI
import TrainTrackerCore

struct WatchingTrainControl: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var plans: JourneyPlanLibrary?
    @State private var showsSheet = false
    @State private var editsInPanel = false
    @State private var problem: String?
    let trip: TrainTrip
    let selectedSegment: JourneyPlanSegment?
    let hasEnded: Bool
    var inSidePanel = false

    var body: some View {
        if library.isWatchingOnly(trip.id) {
            Group {
                if editsInPanel, let plans {
                    RideStopsEditor(trip: trip, plans: plans, isInline: true) { editsInPanel = false }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: TrainTrackerSpacing.space12) { state; Spacer(); action }
                        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) { state; action }
                    }
                }
            }
            .sheet(isPresented: $showsSheet) {
                if let plans {
                    RideStopsEditor(trip: trip, plans: plans, isInline: false) { showsSheet = false }
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .onChange(of: trip.id) { editsInPanel = false; showsSheet = false }
            .alert("Couldn’t save your ride", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
        }
    }

    private var state: some View {
        Label(hasEnded ? "Watched" : "Watching", systemImage: "eye")
            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ttTextSecondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("trainWatchingState")
    }

    private var action: some View {
        Button {
            if selectedSegment != nil {
                do { try library.markAsRiding([trip.id]) } catch { problem = error.localizedDescription }
            } else if plans != nil, RiddenTrainSection(trip: trip).calls.count >= 2 {
                if inSidePanel { editsInPanel = true } else { showsSheet = true }
            } else {
                problem = "Boarding and arrival stops are needed to log your ride. Check again after the train’s next update."
            }
        } label: {
            Text(hasEnded ? "I rode this train" : "I’m on this train")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain).foregroundStyle(Color.ttActionTint)
        .accessibilityIdentifier("markTrainAsRidden")
    }
}

private struct RideStopsEditor: View {
    let trip: TrainTrip
    let plans: JourneyPlanLibrary
    let section: RiddenTrainSection
    let isInline: Bool
    let onClose: () -> Void
    @State private var boarding: String
    @State private var alighting: String
    @State private var problem: String?

    init(trip: TrainTrip, plans: JourneyPlanLibrary, isInline: Bool, onClose: @escaping () -> Void) {
        self.trip = trip
        self.plans = plans
        self.isInline = isInline
        self.onClose = onClose
        let section = RiddenTrainSection(trip: trip)
        self.section = section
        _boarding = State(initialValue: section.calls.first?.id ?? "")
        _alighting = State(initialValue: section.calls.last?.id ?? "")
    }

    private var destinations: ArraySlice<StopTime> {
        guard let index = section.calls.firstIndex(where: { $0.id == boarding }) else { return [] }
        return section.calls.suffix(from: index + 1)
    }

    var body: some View {
        Group {
            if isInline {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    HStack {
                        Text("Your Ride").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        cancel.font(.subheadline)
                    }
                    stopPickers
                    note
                    save
                    Divider().padding(.top, TrainTrackerSpacing.space8)
                }
            } else {
                NavigationStack {
                    Form {
                        Section { stopPickers } footer: { note }
                        save
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                    .navigationTitle("Your Ride")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { cancel } }
                }
            }
        }
        .onChange(of: boarding) {
            if !destinations.contains(where: { $0.id == alighting }) { alighting = destinations.last?.id ?? "" }
            problem = nil
        }
        .onChange(of: alighting) { problem = nil }
    }

    @ViewBuilder private var stopPickers: some View {
        stopPicker("Boarding", selection: $boarding, calls: section.calls.dropLast(), identifier: "rideBoarding")
        stopPicker("Getting off", selection: $alighting, calls: destinations, identifier: "rideDestination")
    }

    private func stopPicker(_ title: LocalizedStringKey, selection: Binding<String>, calls: ArraySlice<StopTime>, identifier: String) -> some View {
        let picker = Picker(title, selection: selection) { rows(calls) }
            .pickerStyle(.menu).accessibilityIdentifier(identifier)
        return Group {
            if isInline {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.caption).foregroundStyle(Color.ttTextSecondary)
                    picker.labelsHidden().fixedSize(horizontal: false, vertical: true)
                }
            } else { picker }
        }
    }

    private var note: some View {
        Text(problem ?? "These are the stops your Travel Log will remember.")
            .font(.footnote).foregroundStyle(problem == nil ? Color.ttTextSecondary : Color.ttStatusDelayed)
    }

    private var cancel: some View { Button("Cancel", action: onClose) }

    private var save: some View {
        Button {
            guard let plan = section.plan(on: trip, from: boarding, to: alighting, at: .now, knownPlans: plans.plans) else {
                problem = "The train has no usable times for these stops. Choose another pair or check again later."
                return
            }
            do {
                try plans.saveRiddenSection(plan, for: trip.id)
                onClose()
            } catch { problem = error.localizedDescription }
        } label: {
            Text("Save My Ride").fontWeight(.semibold).foregroundStyle(Color.ttTextOnBrand)
        }
        .trainTrackerPrimaryAction()
        .controlSize(.large)
        .accessibilityIdentifier("saveRiddenSection")
    }

    private func rows(_ calls: ArraySlice<StopTime>) -> some View {
        ForEach(calls) { stop in Text(stop.station.displayName).tag(stop.id) }
    }
}
