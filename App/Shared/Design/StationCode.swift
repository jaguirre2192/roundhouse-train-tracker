import SwiftUI
import TrainTrackerCore

/// A passenger-facing short station code such as "NYP" or "PAD". Codes are never invented:
/// a station without a letter code returns nil and callers show its name instead.
enum StationShortCode {
    static func code(for station: Station?) -> String? {
        guard let station else { return nil }
        for kind in [StationCodeKind.crs, .sourceNative] {
            if let code = station.codes[kind].flatMap(normalized) {
                return code
            }
        }
        return nil
    }

    /// Two to five ASCII letters or digits with at least one letter. Numeric identifiers such
    /// as EVA or UIC numbers mean nothing on a platform sign, so they are rejected.
    static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (2...5).contains(value.count),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              value.contains(where: \.isLetter) else { return nil }
        return value
    }
}

/// The large station identity on a Line Ticket: the short code when one exists, otherwise the
/// station name at title size. VoiceOver always reads the full name.
struct StationCodeText: View {
    let station: Station?
    let fallbackName: String
    var alignment: HorizontalAlignment = .leading
    var foreground: Color = .ttTextBrand

    var body: some View {
        Group {
            if let code = StationShortCode.code(for: station) {
                Text(code)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
            } else {
                Text(station?.displayName ?? fallbackName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityLabel(station?.displayName ?? fallbackName)
    }
}
