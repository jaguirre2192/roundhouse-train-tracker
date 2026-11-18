import ActivityKit
import SwiftUI
import WidgetKit

struct TrainJourneyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainJourneyAttributes.self) { context in
            TrainActivityLockScreenView(presentation: presentation(context))
                .activityBackgroundTint(TrainActivityPalette.background)
                .activitySystemActionForegroundColor(TrainActivityPalette.primary)
                .widgetURL(context.attributes.deepLinkURL)
        } dynamicIsland: { context in
            let presentation = presentation(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.serviceName, image: TrainTrackerSymbol.train)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrainActivityPalette.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(presentation.shortStatus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrainActivityPalette.status(for: presentation))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TrainActivityExpandedView(presentation: presentation)
                }
            } compactLeading: {
                TrainActivityCompactLeadingView(presentation: presentation)
            } compactTrailing: {
                TrainActivityCompactTrailingView(presentation: presentation)
            } minimal: {
                TrainActivityMinimalView(presentation: presentation)
            }
            .keylineTint(TrainActivityPalette.accent)
            .widgetURL(context.attributes.deepLinkURL)
        }
    }

    private func presentation(_ context: ActivityViewContext<TrainJourneyAttributes>) -> TrainActivityPresentation {
        TrainActivityPresentation(attributes: context.attributes, state: context.state, isStale: context.isStale)
    }
}
