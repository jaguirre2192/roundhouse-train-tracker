import Testing
@testable import TrainTrackerCore

struct RunningStatusWordsTests {
    @Test func differenceUsesPlainWordsAndNothingWhenOnTime() {
        #expect(RunningStatusWords.difference(minutes: 7) == "7 min late")
        #expect(RunningStatusWords.difference(minutes: -3) == "3 min early")
        #expect(RunningStatusWords.difference(minutes: 0) == nil)
    }

    @Test func spokenDifferenceSpellsOutTheUnit() {
        #expect(RunningStatusWords.spokenDifference(minutes: 1) == "1 minute late")
        #expect(RunningStatusWords.spokenDifference(minutes: 12) == "12 minutes late")
        #expect(RunningStatusWords.spokenDifference(minutes: -2) == "2 minutes early")
        #expect(RunningStatusWords.spokenDifference(minutes: 0) == nil)
    }

    @Test func timeLabelsNameTheirSourceWithATrustWord() {
        #expect(RunningStatusWords.timeLabel(.estimated, event: "arrival") == "Estimated arrival")
        #expect(RunningStatusWords.timeLabel(.timetable, event: "departure") == "Timetable departure")
        #expect(RunningStatusWords.timeLabel(.saved, event: "arrival") == "Saved arrival")
    }

    @Test func statusWordsNeverBorrowATrustWord() {
        let trustWords = [JourneyTrust.live, .estimated, .timetable, .saved].map(\.title)
        let status = [RunningStatusWords.onTime, RunningStatusWords.canceled, RunningStatusWords.arrived,
                      RunningStatusWords.ended, RunningStatusWords.late(7), RunningStatusWords.early(2)]
        for word in status {
            for trust in trustWords { #expect(!word.localizedCaseInsensitiveContains(trust)) }
        }
    }
}
