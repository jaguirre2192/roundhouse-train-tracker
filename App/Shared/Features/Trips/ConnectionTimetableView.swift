import SwiftUI
import TrainTrackerCore

struct ConnectionTimetableView: View {
    let timetable: ConnectionTimetable
    var showsAvailableInterval = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: TrainTrackerSpacing.space8) {
                    Image(systemName: "chart.xyaxis.line").accessibilityHidden(true)
                    Text("Connection timetable").font(.subheadline.weight(.semibold))
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    if expanded, let clock = timetable.sharedClockLabel {
                        Text(clock).font(.caption.monospacedDigit()).foregroundStyle(Color.ttTextSecondary)
                            .accessibilityLabel("All times \(clock)")
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.ttActionTint)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("connectionTimetableDisclosure")
            if expanded {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    event(timetable.incoming, title: "Arrival")
                    if let start = timetable.incoming.date, let end = timetable.onward.date {
                        ConnectionTimetableDiagram(arrival: start, departure: end, allowance: timetable.allowanceMinutes,
                                                   isPublished: timetable.published != nil)
                            .frame(height: 40)
                            .accessibilityHidden(true)
                    }
                    event(timetable.onward, title: "Departure")
                    Divider()
                    if showsAvailableInterval, let available = timetable.availableMinutes {
                        Text(available >= 0 ? "\(available) min between trains" : "Departure is \(abs(available)) min before arrival")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    if let margin = timetable.marginMinutes {
                        Text(margin == 0 ? "No time to spare" : "\(abs(margin)) min \(margin < 0 ? "short" : "to spare")")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(margin < 0 ? Color.ttStatusDelayed : Color.ttTextPrimary)
                            .accessibilityIdentifier("connectionTransferMargin")
                    }
                    if let published = timetable.published {
                        Link(destination: published.sourceURL) {
                            Label("Published minimum \(published.minutes) min · \(published.source)", systemImage: "arrow.up.right")
                                .font(.footnote.weight(.medium))
                        }
                        .accessibilityIdentifier("publishedTransferMinimum")
                    } else if let estimate = timetable.planningMinutes {
                        Text("Roundhouse planning estimate · \(estimate) min")
                            .font(.footnote).foregroundStyle(Color.ttTextSecondary)
                            .accessibilityHint("The railway’s minimum is unavailable for this change.")
                    } else {
                        Text("Transfer minimum unavailable")
                            .font(.footnote).foregroundStyle(Color.ttTextSecondary)
                    }
                }
                .padding(.bottom, TrainTrackerSpacing.space8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("connectionTimetableChart")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func event(_ event: ConnectionTimetable.Event, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(event.timingLabel)
                    .font(.caption).foregroundStyle(Color.ttTextSecondary)
            }
            Spacer(minLength: 4)
            if let date = event.date {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(time(date, event: event)).font(.headline.monospacedDigit())
                    if event.usesEstimate, let planned = event.planned {
                        Text(time(planned, event: event)).strikethrough()
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.ttTextSecondary)
                            .accessibilityLabel("Originally \(time(planned, event: event))")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func time(_ date: Date, event: ConnectionTimetable.Event) -> String {
        let zone = event.stationZone ?? .gmt
        let clock = JourneyPlanDateTimePresentation.time(date, timeZoneIdentifier: zone.identifier)
        let zoneName = event.stationZone == nil ? "UTC reference" : (zone.abbreviation(for: date) ?? zone.identifier)
        let reading = timetable.sharedClockLabel == nil ? "\(clock) \(zoneName)" : clock
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if let first = timetable.incoming.date, let last = timetable.onward.date,
           !calendar.isDate(first, inSameDayAs: last) {
            let day = JourneyPlanDateTimePresentation.date(date, timeZoneIdentifier: zone.identifier)
            return "\(day) · \(reading)"
        }
        return reading
    }
}

private struct ConnectionTimetableDiagram: View {
    let arrival: Date
    let departure: Date
    let allowance: Int?
    let isPublished: Bool

    var body: some View {
        Canvas { context, size in
            let departing = departure.timeIntervalSince(arrival)
            let minimum = allowance.map { Double($0) * 60 }
            let earliest = min(0, departing)
            let latest = max(60, departing, minimum ?? 0)
            func x(_ value: TimeInterval) -> CGFloat {
                12 + CGFloat((value - earliest) / (latest - earliest)) * max(0, size.width - 24)
            }
            func line(_ start: CGPoint, _ end: CGPoint, color: Color, width: CGFloat, dash: [CGFloat] = []) {
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(color), style: .init(lineWidth: width, lineCap: .round, dash: dash))
            }
            let arrivingPoint = CGPoint(x: x(0), y: 8)
            let departingPoint = CGPoint(x: x(departing), y: size.height - 8)
            if let minimum {
                if isPublished {
                    let band = CGRect(x: x(0), y: 1, width: x(minimum) - x(0), height: size.height - 2)
                    context.fill(Path(roundedRect: band, cornerRadius: 2), with: .color(.ttRouteActive.opacity(0.2)))
                }
                line(.init(x: x(minimum), y: 1), .init(x: x(minimum), y: size.height - 1),
                     color: isPublished ? .ttTextOperational : (departing < minimum ? .ttStatusDelayed : .ttTextSecondary),
                     width: isPublished ? 2 : 1, dash: isPublished ? [] : [2, 3])
            }
            line(.init(x: 2, y: arrivingPoint.y), arrivingPoint, color: .ttTextBrand, width: 3)
            line(arrivingPoint, departingPoint, color: .ttRouteActive, width: 2, dash: [3, 3])
            line(departingPoint, .init(x: size.width - 2, y: departingPoint.y), color: .ttTextBrand, width: 3)
            for point in [arrivingPoint, departingPoint] {
                let dot = Path(ellipseIn: .init(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(.ttTextBrand))
            }
        }
    }
}
