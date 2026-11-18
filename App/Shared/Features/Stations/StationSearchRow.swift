import SwiftUI
import TrainTrackerCore

struct StationSearchRow: View {
    let station: Station

    var body: some View {
        HStack(spacing: 12) {
            Image(TrainTrackerSymbol.train)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ttRouteActive)
                .frame(width: 32, height: 32)
                .background(
                    Color.ttBackgroundBrandSubtle,
                    in: RoundedRectangle(cornerRadius: TrainTrackerRadius.icon, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(station.displayName)
                    .foregroundStyle(Color.ttTextPrimary)
                Text(StationSearchRowPresentation(station: station).subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct StationSearchRowPresentation: Equatable {
    let subtitle: String

    init(station: Station, locale: Locale = .autoupdatingCurrent) {
        var details = station.operatorHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let country = locale.localizedString(forRegionCode: station.countryCode.uppercased())
            ?? station.countryCode.uppercased()
        if !details.contains(where: { $0.caseInsensitiveCompare(country) == .orderedSame }) {
            details.append(country)
        }
        subtitle = details.joined(separator: " · ")
    }
}
