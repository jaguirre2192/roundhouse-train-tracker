#if DEBUG
import Foundation
import SwiftUI
import TrainTrackerCore

enum TrainActivityPreviewData {
    struct Scenario: Identifiable {
        let id: String
        let state: TrainLiveActivityState
        var isStale = false

        var presentation: TrainActivityPresentation {
            TrainActivityPresentation(
                attributes: TrainActivityPreviewData.attributes, state: state,
                isStale: isStale, referenceDate: TrainActivityPreviewData.referenceDate
            )
        }
    }

    static let referenceDate = ISO8601DateFormatter().date(from: "2026-09-06T18:00:00Z")!

    static var attributes: TrainJourneyAttributes {
        TrainJourneyAttributes(
            schemaVersion: 1,
            activityKey: "preview-selected-train",
            tripID: "us:amtraker:2162:2026-09-06",
            boardingStationID: "us:station:WAS",
            alightingStationID: "us:station:NYP",
            serviceName: "Amtrak · Acela 2162",
            originName: "Washington Union Station",
            destinationName: "New York Penn Station",
            startedAt: referenceDate.timeIntervalSince1970,
            originCode: "WAS", destinationCode: "NYP", isRiding: true
        )
    }

    static var scenarios: [Scenario] {
        let now = referenceDate.timeIntervalSince1970
        return [
            Scenario(id: "Scheduled", state: TrainLiveActivityState(
                phase: .upcoming, focusName: "Washington Union Station", eventTime: now + 1_200,
                timeZoneIdentifier: "America/New_York", timingBasis: .scheduled,
                platform: "9", platformBasis: .scheduled, checkedAt: now - 15, validUntil: now + 180, platformKind: .track
            )),
            Scenario(id: "Delayed", state: TrainLiveActivityState(
                phase: .underway, focusName: "Philadelphia 30th Street", eventTime: now + 1_500,
                timeZoneIdentifier: "America/New_York", timingBasis: .estimated,
                platform: "4", platformBasis: .reported, delayMinutes: 12,
                checkedAt: now - 15, validUntil: now + 180, platformKind: .track
            )),
            Scenario(id: "Platform changed", state: TrainLiveActivityState(
                phase: .departureSoon, focusName: "Washington Union Station", eventTime: now + 900,
                timeZoneIdentifier: "America/New_York", timingBasis: .estimated,
                platform: "12", platformBasis: .reported, platformChanged: true,
                checkedAt: now - 10, validUntil: now + 180, platformKind: .track, boardingPlatformSequence: 0
            )),
            Scenario(id: "Stale", state: TrainLiveActivityState(
                phase: .underway, focusName: "Philadelphia 30th Street", eventTime: now + 600,
                timeZoneIdentifier: "America/New_York", timingBasis: .estimated,
                platform: "4", platformBasis: .reported, delayMinutes: 12,
                checkedAt: now - 600, validUntil: now - 300, platformKind: .track
            )),
            Scenario(id: "Not checked", state: TrainLiveActivityState(
                phase: .upcoming, focusName: "Washington Union Station", eventTime: now + 1_200,
                timeZoneIdentifier: "America/New_York", timingBasis: .scheduled,
                checkedAt: nil, validUntil: now + 180, platformKind: .track
            )),
            Scenario(id: "Cancelled stop", state: TrainLiveActivityState(
                phase: .cancelled, focusName: "Washington Union Station", eventTime: now + 1_200,
                timeZoneIdentifier: "America/New_York", timingBasis: .estimated,
                platform: "12", platformBasis: .reported, checkedAt: now - 15,
                validUntil: now + 180, isStopCancelled: true, platformKind: .track
            )),
            Scenario(id: "Ended", state: TrainLiveActivityState(
                phase: .ended, focusName: "New York Penn Station", eventTime: now - 600,
                timeZoneIdentifier: "America/New_York", timingBasis: .estimated,
                checkedAt: now - 15, validUntil: now + 180, platformKind: .track
            )),
            Scenario(id: "Unknown time zone", state: TrainLiveActivityState(
                phase: .underway, focusName: "Next station", eventTime: now + 1_200,
                timeZoneIdentifier: nil, timingBasis: .scheduled,
                checkedAt: now - 15, validUntil: now + 180, platformKind: .track
            ))
        ]
    }
}

/// An app-side QA harness for deterministic screenshots; the widget itself uses ActivityConfiguration.
struct TrainActivityPreviewGallery: View {
    var body: some View {
        ScrollView {
            TrainActivityPreviewContactSheet()
                .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Live Activity previews")
    }
}

struct TrainActivityPreviewContactSheet: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310, maximum: 460), spacing: 20)], spacing: 24) {
            ForEach(TrainActivityPreviewData.scenarios) { scenario in
                TrainActivityPreviewPanel(scenario: scenario)
            }
        }
    }
}

struct TrainActivityPreviewPanel: View {
    let scenario: TrainActivityPreviewData.Scenario

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scenario.id)
                .font(.headline)
            TrainActivityLockScreenView(presentation: scenario.presentation)
                .background(TrainActivityPalette.background, in: RoundedRectangle(cornerRadius: 24))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(TrainActivityPreviewData.attributes.serviceName)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(scenario.presentation.shortStatus)
                        .foregroundStyle(TrainActivityPalette.status(for: scenario.presentation))
                }
                .font(.caption.weight(.semibold))
                TrainActivityExpandedView(presentation: scenario.presentation)
            }
            .foregroundStyle(TrainActivityPalette.primary)
            .padding(16)
            .background(.black, in: RoundedRectangle(cornerRadius: 28))

            HStack(spacing: 16) {
                HStack(spacing: 32) {
                    TrainActivityCompactLeadingView(presentation: scenario.presentation)
                    TrainActivityCompactTrailingView(presentation: scenario.presentation)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.black, in: Capsule())
                TrainActivityMinimalView(presentation: scenario.presentation)
                    .frame(width: 36, height: 36)
                    .background(.black, in: Circle())
            }
        }
    }
}

#Preview("Live Activity state gallery") {
    TrainActivityPreviewGallery()
}
#endif
