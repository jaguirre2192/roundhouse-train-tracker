import AppIntents

struct TrainJourneyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextTrainIntent(),
            phrases: [
                "When’s my next train in \(.applicationName)",
                "When does my train leave in \(.applicationName)",
                "Next train in \(.applicationName)",
            ],
            shortTitle: "Next Train",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: OpenSavedTrainIntent(),
            phrases: [
                "Open a saved train in \(.applicationName)",
                "Open \(\.$target) in \(.applicationName)",
            ],
            shortTitle: "Open Saved Train",
            systemImageName: "tram.fill"
        )
        AppShortcut(
            intent: StartTrainLiveActivityIntent(),
            phrases: [
                "Start a Live Activity in \(.applicationName)",
                "Track \(\.$train) with \(.applicationName)",
            ],
            shortTitle: "Start Live Activity",
            systemImageName: "livephoto"
        )
        AppShortcut(
            intent: StopTrainLiveActivityIntent(),
            phrases: ["Stop the Live Activity in \(.applicationName)"],
            shortTitle: "Stop Live Activity",
            systemImageName: "stop.circle"
        )
    }
}
