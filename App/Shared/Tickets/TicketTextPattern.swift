import Foundation

/// Small Foundation regex adapter shared by the bounded free-text parsers.
enum TicketTextPattern {
    private final class RegexCache: @unchecked Sendable {
        private let values = NSCache<NSString, NSRegularExpression>()

        init() {
            values.countLimit = 128
        }

        func expression(for pattern: String) -> NSRegularExpression? {
            let key = pattern as NSString
            if let cached = values.object(forKey: key) { return cached }
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { return nil }
            values.setObject(expression, forKey: key)
            return expression
        }
    }

    private static let cache = RegexCache()

    static func expression(_ pattern: String) -> NSRegularExpression? {
        cache.expression(for: pattern)
    }

    static func ranges(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = expression(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text)
        }
    }

    static func contains(_ pattern: String, in text: String) -> Bool {
        !ranges(pattern, in: text).isEmpty
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = expression(pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func removingPrefix(_ pattern: String, from text: String) -> String {
        guard let range = ranges(pattern, in: text).first, range.lowerBound == text.startIndex else { return text }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    static func containsWord(_ word: String, in text: String) -> Bool {
        contains("(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])", in: text)
    }
}
