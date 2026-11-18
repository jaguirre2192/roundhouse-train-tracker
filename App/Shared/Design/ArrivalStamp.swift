import SwiftUI

/// The mark a finished journey gets: an inked stamp, struck slightly askew. On the live ticket it
/// lands once, the first time the journey is seen after arriving; after that it is simply there.
struct ArrivalStamp: View {
    let place: String
    let date: Date
    var timeZone: TimeZone = .autoupdatingCurrent
    var color: Color = .ttRouteOnInk
    var compact = false
    /// Replaces the place-and-date line; on a stub the date is already on the counterfoil.
    var detailOverride: String? = nil

    var body: some View {
        VStack(spacing: 1) {
            Text("Arrived")
                .font((compact ? Font.caption2 : Font.subheadline).weight(.heavy))
                .tracking(compact ? 1.4 : 2.2)
                .textCase(.uppercase)
            Text(detail)
                .font(.system(size: compact ? 8 : 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 7 : 12)
        .padding(.vertical, compact ? 4 : 7)
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous)
                .strokeBorder(color, lineWidth: compact ? 1.5 : 2.5)
        }
        .padding(compact ? 2 : 3)
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous)
                .strokeBorder(color.opacity(0.55), lineWidth: 1)
        }
        .opacity(0.92)
        .rotationEffect(.degrees(-9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Arrived at \(place)")
    }

    private var detail: String {
        if let detailOverride { return "\(detailOverride) · \(place)".uppercased() }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = timeZone
        return "\(place) · \(date.formatted(style))".uppercased()
    }
}

/// Strikes the stamp onto a ticket once per journey, then leaves it in place.
struct ArrivalStampStrike: ViewModifier {
    let journeyID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false
    @State private var strikes = 0

    private static let seenKey = "arrivalStamp.seenJourneyIDs"

    func body(content: Content) -> some View {
        content
            .scaleEffect(landed || reduceMotion ? 1 : 2.4)
            .opacity(landed ? 1 : 0)
            .preferredSensoryFeedback(.impact(weight: .heavy), trigger: strikes)
            .onAppear {
                var seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
                if seen.contains(journeyID) {
                    landed = true
                    return
                }
                seen.append(journeyID)
                UserDefaults.standard.set(Array(seen.suffix(200)), forKey: Self.seenKey)
                withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.3, dampingFraction: 0.55).delay(0.45)) {
                    landed = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    strikes += 1
                }
            }
    }
}
