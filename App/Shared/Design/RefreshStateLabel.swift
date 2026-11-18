import SwiftUI

/// A refresh symbol that shows what happened: it turns while checking, becomes a tick that
/// bounces when the check succeeds, and a warning that wiggles when it fails, then settles back.
struct RefreshStateLabel: View {
    let isRefreshing: Bool
    /// Asked just after a check ends, so it reflects that check.
    let didFail: () -> Bool

    private enum Outcome { case succeeded, failed }

    @State private var outcome: Outcome?
    @State private var successes = 0
    @State private var failures = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .symbolEffect(.rotate, isActive: isRefreshing && !reduceMotion)
            .symbolEffect(.bounce, value: successes)
            .symbolEffect(.wiggle, value: failures)
            .contentTransition(.symbolEffect(.replace))
            .onChange(of: isRefreshing) { wasRefreshing, isRefreshing in
                guard wasRefreshing, !isRefreshing else { return }
                Task { @MainActor in
                    // Let the store record this check's result before reading it.
                    try? await Task.sleep(for: .milliseconds(60))
                    let failed = didFail()
                    outcome = failed ? .failed : .succeeded
                    if failed { failures += 1 } else { successes += 1 }
                    try? await Task.sleep(for: .seconds(1.6))
                    outcome = nil
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: outcome)
    }

    private var symbol: String {
        switch outcome {
        case .succeeded: "checkmark"
        case .failed: "exclamationmark.arrow.triangle.2.circlepath"
        case nil: "arrow.clockwise"
        }
    }
}
