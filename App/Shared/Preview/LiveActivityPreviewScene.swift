#if DEBUG
import ActivityKit
import SwiftUI
import TrainTrackerCore

struct LiveActivityPreviewScene: View {
    @State private var errorMessage: String?
    @State private var selected = 0
    @State private var nativeStatus: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-LiveActivityScenario"), arguments.indices.contains(index + 1) {
            let value = arguments[index + 1]
            _selected = State(initialValue: TrainActivityPreviewData.scenarios.firstIndex {
                $0.id.lowercased().replacingOccurrences(of: " ", with: "-") == value
            } ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TrainActivityPreviewPanel(scenario: TrainActivityPreviewData.scenarios[selected])
                    .padding(20)
                if let nativeStatus { Text(nativeStatus).font(.caption).padding(.horizontal, 20) }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Live Activity")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if ProcessInfo.processInfo.arguments.contains("-StartLiveActivityPreview") {
                    await startNativePreview()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Preview state", selection: $selected) {
                        ForEach(Array(TrainActivityPreviewData.scenarios.enumerated()), id: \.offset) { index, scenario in
                            Text(scenario.id).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Start on Lock Screen") { Task { await startNativePreview() } }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("End preview") {
                        Task {
                            for activity in Activity<TrainJourneyAttributes>.activities {
                                await activity.end(nil, dismissalPolicy: .immediate)
                            }
                        }
                    }
                }
            }
            .alert("Preview", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func startNativePreview() async {
        for activity in Activity<TrainJourneyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let sample = TrainActivityPreviewData.scenarios[selected].state
        let now = Date.now.timeIntervalSince1970
        let offset = now - TrainActivityPreviewData.referenceDate.timeIntervalSince1970
        let state = TrainLiveActivityState(
            phase: sample.phase, focusName: sample.focusName,
            eventTime: sample.eventTime.map { $0 + offset }, timeZoneIdentifier: sample.timeZoneIdentifier,
            timingBasis: sample.timingBasis, platform: sample.platform, platformBasis: sample.platformBasis,
            platformChanged: sample.platformChanged, delayMinutes: sample.delayMinutes,
            checkedAt: sample.checkedAt.map { $0 + offset }, validUntil: sample.validUntil + offset,
            isStopCancelled: sample.isStopCancelled,
            platformKind: sample.platformKind, platformSource: sample.platformSource,
            boardingPlatformSequence: sample.boardingPlatformSequence
        )
        do {
            _ = try Activity.request(
                attributes: TrainActivityPreviewData.attributes,
                content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.validUntil)),
                pushType: nil
            )
            nativeStatus = "Live Activity started in the system."
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
