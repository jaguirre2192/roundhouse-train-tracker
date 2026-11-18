import SwiftUI

struct JourneyExperienceContent: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 0
    let presentation: JourneyExperiencePresentation

    /// Two columns need room for a full ticket beside the map and stops: two ~400pt columns,
    /// each wider than the iPhone ticket, plus the gutter. That fits iPhone Duo's inner display
    /// and iPad portrait with the sidebar hidden; narrower panes stack instead of squeezing.
    static let twoColumnMinimumWidth: CGFloat = 780
    /// Stacked on regular width (a detail beside the iPad sidebar), the ticket, map and stops
    /// share one column up to this width; wider, the ticket stops reading as a ticket.
    static let stackedMaximumWidth: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
            if usesTwoColumns {
                // Two equal columns: the ticket on the leading side, the map above the stops on
                // the trailing side. An even split keeps content clear of a centre fold.
                HStack(alignment: .top, spacing: TrainTrackerSpacing.space24) {
                    // Equal columns; the content width cap keeps each near ticket size.
                    nextStep.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
                        routeMap
                        JourneyRouteTimeline(presentation: presentation)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                // The detail caps the whole stack (TripDetailView), so every card shares its edges.
                nextStep
                if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
                    routeMap
                }
                JourneyRouteTimeline(presentation: presentation)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private var usesTwoColumns: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
            && availableWidth >= Self.twoColumnMinimumWidth
    }

    private var routeMap: some View {
        TripRouteMapView(trip: presentation.trip, chrome: .compact)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: TrainTrackerRadius.hero, style: .continuous))
    }

    private var nextStep: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
            LiveTripTicketHero(presentation: presentation, showsStatusBadge: false)
            if let note = presentation.unreportedScheduledStopText {
                Text(note).font(.subheadline).foregroundStyle(Color.ttTextSecondary)
            }
            TripUpdatesRow(experience: presentation)

            TripInsightHeadline(
                presentation: ActiveTripCardPresentation(
                    trip: presentation.trip, routeTimeZones: presentation.timeZones.routeTimeZones,
                    referenceDate: presentation.referenceDate,
                    lastSuccessfulCheck: presentation.lastSuccessfulCheck,
                    lastRefreshFailed: presentation.refreshFailed,
                    selectedSegment: presentation.selectedSegment
                ),
                timeZoneIdentifier: { presentation.timeZones.timeZoneIdentifier(for: $0) }
            )
            .padding(.top, TrainTrackerSpacing.space4)

            if AmtrakerAttributionLink.applies(to: presentation.trip) {
                AmtrakerAttributionLink()
            }

            ForEach(presentation.currentAlerts) { alert in
                DisruptionBanner(alert: alert)
            }
        }
    }
}

private struct JourneyReferenceDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// Nil in normal use; deterministic preview/test journeys provide a clock.
    var journeyReferenceDate: Date? {
        get { self[JourneyReferenceDateKey.self] }
        set { self[JourneyReferenceDateKey.self] = newValue }
    }
}
