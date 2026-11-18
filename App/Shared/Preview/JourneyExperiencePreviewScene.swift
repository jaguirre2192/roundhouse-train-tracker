#if DEBUG
import SwiftUI

struct JourneyExperiencePreviewScene: View {
    @State private var scenario: JourneyExperienceScenario

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let value = arguments.firstIndex(of: "-JourneyExperienceScenario").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        _scenario = State(initialValue: JourneyExperienceScenario.allCases.first {
            $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") == value
        } ?? .departure)
    }

    var body: some View {
        JourneyExperiencePreviewJourney(scenario: $scenario)
            .id(scenario)
    }
}

private struct JourneyExperiencePreviewJourney: View {
    private let fixture: JourneyExperiencePreviewData
    @State private var trips: TripLibrary
    @State private var plans: JourneyPlanLibrary
    @Binding var scenario: JourneyExperienceScenario

    init(scenario: Binding<JourneyExperienceScenario>) {
        _scenario = scenario
        let fixture = JourneyExperiencePreviewData.make(scenario.wrappedValue)
        self.fixture = fixture
        let trips = TripLibrary(
            trips: fixture.trips, pushCoordinator: JourneyPlanPreviewPushCoordinator(),
            archive: nil, automaticRefreshEnabled: false
        )
        _trips = State(initialValue: trips)
        _plans = State(initialValue: try! JourneyPlanLibrary(
            tripLibrary: trips, archive: JourneyPlanPreviewArchive(plans: [fixture.plan])
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if scenario == .connection {
                    JourneyPlanDetailView(plan: fixture.plan, planLibrary: plans)
                } else {
                    TripDetailView(trip: fixture.trips[0], selectedSegment: fixture.plan.outbound.selectedSegments?.first)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Preview journey", selection: $scenario) {
                        ForEach(JourneyExperienceScenario.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        // Navigation destinations inherit the fixture libraries and clock too.
        .environment(trips)
        .environment(plans)
        .environment(\.journeyReferenceDate, fixture.referenceDate)
    }
}
#endif
