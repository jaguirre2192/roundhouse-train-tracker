import SwiftUI

/// The Lock Screen as a compact ink Line Ticket: train and status, station codes on a rail,
/// a tear line, then the next stop, its time and platform. Directly reusable in an app-side
/// DEBUG gallery without ActivityKit hosting.
struct TrainActivityLockScreenView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: TrainActivityPresentation

    var body: some View {
        if let boarding = presentation.boardingPlatform, let departure = presentation.timeText {
            boardingSign(platform: boarding, departure: departure)
        } else {
            journeyTicket
        }
    }

    private func boardingSign(platform: String, departure: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.state.platformChanged ? "\(presentation.platformNoun) changed" : presentation.platformNoun)
                    .font(.caption.weight(.semibold)).foregroundStyle(TrainActivityPalette.secondary)
                Text(platform).font(.largeTitle.bold().monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(presentation.boardingDepartureLabel).font(.caption.weight(.semibold))
                    .foregroundStyle(TrainActivityPalette.secondary)
                Text("\(departure) \(presentation.timeZoneText)").font(.title3.bold().monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .foregroundStyle(TrainActivityPalette.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.attributes.serviceName). \(presentation.platformLabel) \(platform). \(presentation.boardingDepartureLabel) \(departure), \(presentation.timeZoneText)")
        .accessibilityIdentifier("boardingLockScreenSign")
    }

    private var journeyTicket: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(presentation.attributes.serviceName)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(TrainActivityPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                TrainActivityStatusPill(presentation: presentation)
            }

            TrainActivityRoute(attributes: presentation.attributes)

            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay {
                    Line()
                        .stroke(TrainActivityPalette.rail, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 4]))
                }
                .accessibilityHidden(true)

            TrainActivityStub(presentation: presentation)
        }
        .foregroundStyle(TrainActivityPalette.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilitySummary)
        .accessibilityHint("Opens this selected train journey")
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// Status written out with a dot, in the on-ink status colour.
struct TrainActivityStatusPill: View {
    let presentation: TrainActivityPresentation

    var body: some View {
        let color = TrainActivityPalette.status(for: presentation)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(presentation.headerStatus)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay { Capsule().stroke(color, lineWidth: 0.75) }
    }
}

/// Codes joined by a route rail, falling back to names when a station has no letter code.
struct TrainActivityRoute: View {
    let attributes: TrainJourneyAttributes

    var body: some View {
        if let origin = attributes.originCode, let destination = attributes.destinationCode {
            HStack(spacing: 10) {
                Text(origin)
                ZStack {
                    Capsule().fill(TrainActivityPalette.route).frame(height: 2)
                    HStack {
                        Circle().fill(TrainActivityPalette.route).frame(width: 7, height: 7)
                        Spacer(minLength: 0)
                        Circle().stroke(TrainActivityPalette.primary, lineWidth: 1.5).frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
                Text(destination)
            }
            .font(.title2.weight(.bold))
            .lineLimit(1)
        } else {
            Text("\(attributes.originName) → \(attributes.destinationName)")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// Next stop, its time and the platform in equal columns, as on the app's ticket stub.
struct TrainActivityStub: View {
    let presentation: TrainActivityPresentation

    var body: some View {
        // Station names can be long and have no code here, so the station takes the spare
        // width while time and platform size to their content.
        HStack(alignment: .top, spacing: 16) {
            // A long station name wraps to a second line rather than shrinking, so the stub's
            // type size is the same in every state.
            field(presentation.stubFocusLabel, presentation.stubFocusValue, valueLines: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            field(presentation.shortTimingLabel, presentation.timeText ?? "—", countdown: presentation.finalApproach)
                .fixedSize()
            field(presentation.platformNoun, presentation.platform ?? "—",
                  valueColor: presentation.platform == nil ? TrainActivityPalette.secondary : TrainActivityPalette.status(for: presentation))
                .fixedSize()
        }
    }

    private func field(
        _ label: String,
        _ value: String,
        valueColor: Color = TrainActivityPalette.primary,
        valueLines: Int = 1,
        countdown: ClosedRange<Date>? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(TrainActivityPalette.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(valueLines)
                .fixedSize(horizontal: false, vertical: true)
            if let countdown {
                // The system advances this every second without a push.
                (Text("in ") + Text(timerInterval: countdown, countsDown: true, showsHours: false))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(TrainActivityPalette.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct TrainActivityJourneySummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: TrainActivityPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.focusLabel)
                    .font(.caption)
                    .foregroundStyle(TrainActivityPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(presentation.focusName)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if let time = presentation.timeText {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(presentation.shortTimingLabel)
                        .font(.caption2)
                        .foregroundStyle(TrainActivityPalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(time)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(presentation.timeZoneText)
                        .font(.caption2)
                        .foregroundStyle(TrainActivityPalette.secondary)
                }
                .frame(minWidth: 68, maxWidth: 118, alignment: .trailing)
            }
        }
    }
}

struct TrainActivityFooter: View {
    let presentation: TrainActivityPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let platform = presentation.platform {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(presentation.platformLabel)
                        .foregroundStyle(TrainActivityPalette.secondary)
                    Text(platform)
                        .fontWeight(.bold)
                        .foregroundStyle(TrainActivityPalette.status(for: presentation))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            } else {
                Text(presentation.evidenceText)
                    .foregroundStyle(TrainActivityPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Label(presentation.actionTitle, systemImage: "arrow.up.right")
                .fontWeight(.semibold)
                .foregroundStyle(TrainActivityPalette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption2)
    }
}
