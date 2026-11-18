import SwiftUI

/// A short value — a time, a track, a delay — whose characters turn over like a departure board
/// when it changes. Only the characters that differ move. Reduce Motion cross-fades instead, and
/// longer text is left as plain text, which can truncate.
struct FlapText: View {
    let text: String
    var font: Font = .body
    var color: Color = .ttTextPrimary
    var weight: Font.Weight = .semibold

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Beyond this a value is a name, not a reading, and names don't flip.
    static let longestFlappingText = 9

    init(_ text: String, font: Font = .body, color: Color = .ttTextPrimary, weight: Font.Weight = .semibold) {
        self.text = text
        self.font = font
        self.color = color
        self.weight = weight
    }

    var body: some View {
        if reduceMotion || text.count > Self.longestFlappingText {
            Text(text)
                .font(font.weight(weight))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: text)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                    FlapCharacter(character: character, delay: Double(index) * 0.035)
                }
            }
            .font(font.weight(weight))
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }
    }
}

/// One cell of the board. It turns away, changes, and turns back.
private struct FlapCharacter: View {
    let character: Character
    let delay: Double

    @State private var shown: Character
    @State private var angle: Double = 0

    init(character: Character, delay: Double) {
        self.character = character
        self.delay = delay
        _shown = State(initialValue: character)
    }

    var body: some View {
        Text(String(shown))
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .opacity(1 - abs(angle) / 90 * 0.7)
            .onChange(of: character) { _, new in
                withAnimation(.easeIn(duration: 0.13).delay(delay)) {
                    angle = -90
                } completion: {
                    var instantly = Transaction()
                    instantly.disablesAnimations = true
                    withTransaction(instantly) {
                        shown = new
                        angle = 90
                    }
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) { angle = 0 }
                }
            }
    }
}
