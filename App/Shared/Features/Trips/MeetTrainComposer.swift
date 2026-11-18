import SwiftUI
import TrainTrackerCore

struct MeetTrainComposer: View {
    @Environment(TripLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var chosenID: String?
    @State private var note = ""
    @State private var resolvedZone: TimeZone?
    @State private var board: TripSharingClient.ArrivalLink?
    @State private var problem: String?
    @State private var creating = false
    @FocusState private var editingNote: Bool

    let trip: TrainTrip
    let selection: MeetTrainSelection
    let zones: TripDetailTimeZoneContext

    init(trip: TrainTrip, selection: MeetTrainSelection, segment: JourneyPlanSegment?, plans: [TrackedJourneyPlan]) {
        self.trip = trip
        self.selection = selection
        _chosenID = State(initialValue: selection.bookedCall?.id)
        zones = TripDetailTimeZoneContext(trip: trip, plans: plans, additionalPlaces: segment.map { [$0.from, $0.to] } ?? [])
    }

    private var stop: StopTime? { selection.calls.first { $0.id == chosenID } }
    private var zone: TimeZone? {
        guard let stop else { return nil }
        return zones.timeZoneIdentifier(for: stop).flatMap(TimeZone.init(identifier:))
            ?? StationTimeZoneResolver.cached(for: stop.station.id) ?? resolvedZone
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                    header
                    if selection.bookedCall == nil {
                        Picker("Getting off at", selection: $chosenID) {
                            Text("Choose a stop").tag(Optional<String>.none)
                            ForEach(selection.calls) { call in Text(call.station.displayName).tag(Optional(call.id)) }
                        }
                        .accessibilityIdentifier("meetArrivalStop")
                    }
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                        HStack {
                            Text("Where to meet").font(.headline)
                            Spacer()
                            if editingNote {
                                Button("Done editing") { editingNote = false }
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("meetFinishNote")
                            }
                        }
                        TextField("Optional meeting note", text: $note, axis: .vertical)
                            .lineLimit(2...4).focused($editingNote)
                            .padding(LayoutMetrics.cardInset).trainTrackerSurface()
                            .accessibilityIdentifier("meetArrivalNote")
                    }
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                        Text("Anyone with the link can view this arrival and your note in a browser.")
                            .font(.footnote).foregroundStyle(Color.ttTextSecondary)
                        actions
                        sharingDetails
                    }
                }
                .padding(LayoutMetrics.pageInset)
                .frame(maxWidth: 460, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .trainTrackerPageBackground()
            .navigationTitle("Meet My Train").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .onChange(of: chosenID) { clearLink(); resolvedZone = nil }
        .onChange(of: note) {
            if note.unicodeScalars.count > 180 { note = String(String.UnicodeScalarView(note.unicodeScalars.prefix(180))) }
            clearLink()
        }
        .task(id: stop?.id) {
            guard zone == nil, let station = stop?.station else { return }
            let result = await StationTimeZoneResolver.resolve(station)
            if !Task.isCancelled { resolvedZone = result }
        }
    }

    private var header: some View {
        let service = LiveLineTicketPresentation.serviceName(for: trip)
        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text(stop?.station.displayName ?? service)
                .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meetArrivalStation")
            if stop != nil { Text(service).font(.headline) }
            if let stop, let time = stop.scheduledArrival {
                Divider().overlay(Color.ttTextOnBrand.opacity(0.45))
                Text("Scheduled arrival").font(.caption)
                Text(MeetTrainSelection.timeLabel(time, zone: zone)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(Color.ttTextOnBrand).frame(maxWidth: .infinity, alignment: .leading)
        .padding(TrainTrackerSpacing.space20)
        .background(Color.ttBackgroundBrand, in: RoundedRectangle(cornerRadius: TrainTrackerRadius.card))
    }

    private var sharingDetails: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Label("Your ticket and device location stay private.", systemImage: "lock")
            if let board {
                Label("Closes 1 hour after a reported arrival, or by \(MeetTrainSelection.timeLabel(board.expiresAt, zone: zone)).", systemImage: "clock")
            } else {
                Label("Closes 1 hour after a reported arrival.", systemImage: "clock")
            }
        }
        .font(.footnote).foregroundStyle(Color.ttTextSecondary)
    }

    @ViewBuilder private var actions: some View {
        if let problem {
            Text(problem).font(.subheadline).foregroundStyle(Color.ttTextOperational)
                .accessibilityIdentifier("meetArrivalProblem")
        }
        if let board {
            ShareLink(item: board.url, subject: Text("Meet my train"), message: Text("You can follow my arrival in your browser.")) {
                Label("Share Arrival Board", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .trainTrackerPrimaryAction().controlSize(.large).accessibilityIdentifier("shareArrivalBoard")
        } else {
            Button {
                editingNote = false
                Task { await create() }
            } label: {
                HStack {
                    if creating { ProgressView().tint(Color.ttTextOnBrand) }
                    Text(creating ? "Creating Link…" : "Create Arrival Link").fontWeight(.semibold)
                }.frame(maxWidth: .infinity)
            }
            .trainTrackerPrimaryAction().controlSize(.large)
            .disabled(stop == nil || creating).accessibilityIdentifier("createArrivalBoard")
        }
    }

    private func clearLink() { board = nil; problem = nil }

    @MainActor private func create() async {
        guard !creating, let stop else { return }
        creating = true
        defer { creating = false }
        let submittedNote = note
        let submittedID = stop.id
        do {
            let result = try await library.arrivalBoard(for: trip, stop: stop, zone: zone, note: submittedNote)
            guard chosenID == submittedID, note == submittedNote else { return }
            board = result
            problem = nil
        } catch {
            guard chosenID == submittedID, note == submittedNote else { return }
            problem = error.localizedDescription
        }
    }
}
