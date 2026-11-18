import SwiftUI

/// The latest matching route is one tap from the station fields. Earlier routes share the
/// history menu so the primary action stays in reach at any history size.
struct RecentRouteShortcut: View {
    let suggested: RecentRailRoute?
    let alternatives: [RecentRailRoute]
    let history: RailPlaceRecents
    let select: (RecentRailRoute) -> Void

    var body: some View {
        HStack(spacing: TrainTrackerSpacing.space8) {
            if let suggested { suggestedRouteButton(suggested) }
            Menu {
                if !alternatives.isEmpty {
                    Section {
                        ForEach(alternatives) { route in
                            Button { select(route) } label: { routeLabel(route) }
                                .accessibilityLabel("\(route.originTitle) to \(route.destinationTitle)")
                        }
                    }
                }
                if history.routes.count > 1 {
                    Menu("Remove a Route", systemImage: "minus.circle") {
                        ForEach(history.routes) { route in
                            Button(role: .destructive) { history.remove(route) } label: { routeLabel(route) }
                        }
                    }
                }
                Button("Clear Recent Routes", systemImage: "trash", role: .destructive) { history.clearRoutes() }
            } label: {
                if suggested == nil {
                    HStack(spacing: TrainTrackerSpacing.space12) {
                        Image(systemName: "clock.arrow.circlepath").frame(width: LayoutMetrics.iconRailWidth)
                        Text("Recent Routes").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                } else {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Recent Routes")
            .accessibilityIdentifier("recentJourneyRoutesMenu")
        }
    }

    private func suggestedRouteButton(_ route: RecentRailRoute) -> some View {
        Button {
            select(route)
        } label: {
            HStack(spacing: TrainTrackerSpacing.space12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body)
                    .frame(width: LayoutMetrics.iconRailWidth)
                    .foregroundStyle(Color.ttActionTint)
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                    Text("Recent Route")
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
                    routeLabel(route)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ttActionTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use recent route, \(route.originTitle) to \(route.destinationTitle)")
        .accessibilityHint("Fills From and To using your selected travel dates.")
        .accessibilityIdentifier("useRecentJourneyRoute")
    }

    private func routeLabel(_ route: RecentRailRoute) -> Text {
        Text("\(route.originTitle) \(Image(systemName: "arrow.forward")) \(route.destinationTitle)")
    }
}

private extension RecentRailRoute {
    var originTitle: String { RailPlacePickerPresentation(place: origin).title }
    var destinationTitle: String { RailPlacePickerPresentation(place: destination).title }
}
