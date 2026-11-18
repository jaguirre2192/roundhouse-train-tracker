import Foundation
import XCTest
@testable import TrainTracker

@MainActor
final class CalendarImportOptionsTests: XCTestCase {
    func testDefaultPresetPreservesExistingFourteenPastAndOneHundredTwentyFutureDays() throws {
        let calendar = try calendar()
        let reference = try date(2026, 3, 5, hour: 10, calendar: calendar)
        let window = try CalendarImportOptions().dateInterval(referenceDate: reference, calendar: calendar)

        XCTAssertEqual(window, CalendarImportStore.defaultWindow(referenceDate: reference, calendar: calendar))
    }

    func testUpcomingPresetsStartAtReferenceDateAndUseCalendarDays() throws {
        let calendar = try calendar()
        let reference = try date(2026, 3, 5, hour: 10, calendar: calendar)
        for (preset, days) in [(CalendarImportOptions.DatePreset.next30Days, 30), (.next120Days, 120)] {
            let window = try CalendarImportOptions(datePreset: preset).dateInterval(referenceDate: reference, calendar: calendar)
            XCTAssertEqual(window.start, reference)
            XCTAssertEqual(calendar.dateComponents([.day], from: window.start, to: window.end).day, days)
            XCTAssertEqual(calendar.component(.hour, from: window.end), 10)
        }
    }

    func testCustomRangeIncludesTheWholeFinalDay() throws {
        let calendar = try calendar()
        let start = try date(2026, 9, 15, hour: 18, calendar: calendar)
        let end = try date(2026, 9, 16, hour: 8, calendar: calendar)
        let window = try options(start, end).dateInterval(calendar: calendar)

        XCTAssertEqual(window.start, try date(2026, 9, 15, calendar: calendar))
        XCTAssertEqual(window.end, try date(2026, 9, 17, calendar: calendar))
    }

    func testOneCustomDayAcrossSpringDaylightSavingChangeIsTwentyThreeHours() throws {
        let calendar = try calendar()
        let day = try date(2026, 3, 8, hour: 12, calendar: calendar)
        let window = try options(day, day).dateInterval(calendar: calendar)

        XCTAssertEqual(window.duration, 23 * 3600)
        XCTAssertEqual(calendar.component(.day, from: window.end), 9)
        XCTAssertEqual(calendar.component(.hour, from: window.end), 0)
    }

    func testOneCustomDayAcrossFallDaylightSavingChangeIsTwentyFiveHours() throws {
        let calendar = try calendar()
        let day = try date(2026, 11, 1, hour: 12, calendar: calendar)
        let window = try options(day, day).dateInterval(calendar: calendar)

        XCTAssertEqual(window.duration, 25 * 3600)
        XCTAssertEqual(calendar.component(.day, from: window.end), 2)
        XCTAssertEqual(calendar.component(.hour, from: window.end), 0)
    }

    func testCustomDatesCompareDaysRatherThanTimeOfDay() throws {
        let calendar = try calendar()
        let start = try date(2026, 9, 15, hour: 18, calendar: calendar)
        let end = try date(2026, 9, 15, hour: 8, calendar: calendar)
        XCTAssertEqual(try options(start, end).dateInterval(calendar: calendar).duration, 24 * 3600)
    }

    func testCustomRangeAllowsExactlyThreeHundredSixtySixInclusiveDaysAcrossLeapYear() throws {
        let calendar = try calendar()
        let start = try date(2028, 1, 1, calendar: calendar)
        let end = try date(2028, 12, 31, calendar: calendar)
        let window = try options(start, end).dateInterval(calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.day], from: window.start, to: window.end).day, 366)
    }

    func testCustomRangeRejectsThreeHundredSixtySevenInclusiveDays() throws {
        let calendar = try calendar()
        let start = try date(2028, 1, 1, calendar: calendar)
        let end = try date(2029, 1, 1, calendar: calendar)
        XCTAssertThrowsError(try options(start, end).dateInterval(calendar: calendar)) {
            XCTAssertEqual($0 as? CalendarImportOptions.ValidationError, .rangeTooLong)
        }
    }

    func testReversedAndMissingCustomDatesAreRejected() throws {
        let calendar = try calendar()
        let start = try date(2026, 9, 16, calendar: calendar)
        let end = try date(2026, 9, 15, calendar: calendar)
        XCTAssertThrowsError(try options(start, end).dateInterval(calendar: calendar)) {
            XCTAssertEqual($0 as? CalendarImportOptions.ValidationError, .endBeforeStart)
        }
        XCTAssertThrowsError(try CalendarImportOptions(datePreset: .custom).dateInterval()) {
            XCTAssertEqual($0 as? CalendarImportOptions.ValidationError, .missingCustomDates)
        }
    }

    func testInvalidDateIsRejectedBeforeCalendarArithmetic() {
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try options(invalid, .now).dateInterval()) {
            XCTAssertEqual($0 as? CalendarImportOptions.ValidationError, .invalidDates)
        }
    }

    func testPersistenceDistinguishesAllCalendarsFromAnExplicitEmptySelection() throws {
        let name = "CalendarImportOptionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CalendarImportPreferences(defaults: defaults)
        XCTAssertNil(preferences.load().selectedCalendarIDs)

        try preferences.save(CalendarImportOptions(selectedCalendarIDs: []))
        XCTAssertEqual(preferences.load().selectedCalendarIDs, [])

        try preferences.save(CalendarImportOptions(selectedCalendarIDs: nil))
        XCTAssertNil(preferences.load().selectedCalendarIDs)
    }

    func testPreferencesRoundTripCustomRangeAndSelectedSources() throws {
        let name = "CalendarImportOptionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let calendar = try calendar()
        let value = CalendarImportOptions(
            selectedCalendarIDs: ["personal", "work"], datePreset: .custom,
            customStartDate: try date(2026, 9, 15, calendar: calendar),
            customEndDate: try date(2026, 9, 30, calendar: calendar)
        )
        try CalendarImportPreferences(defaults: defaults, key: "options").save(value)

        XCTAssertEqual(CalendarImportPreferences(defaults: defaults, key: "options").load(), value)
    }

    func testCorruptPreferencesFallBackToDefaultOptions() throws {
        let name = "CalendarImportOptionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: "options")

        XCTAssertEqual(CalendarImportPreferences(defaults: defaults, key: "options").load(), CalendarImportOptions())
    }

    func testUnavailableCalendarSelectionIsNotSummarizedAsAllCalendars() {
        XCTAssertEqual(CalendarImportOptions().calendarSummary(availableCalendars: []), "All calendars")
        XCTAssertEqual(CalendarImportOptions(selectedCalendarIDs: []).calendarSummary(availableCalendars: []), "No calendars selected")
        XCTAssertEqual(CalendarImportOptions(selectedCalendarIDs: ["removed"]).calendarSummary(availableCalendars: []), "1 selected calendar")
    }

    private func options(_ start: Date, _ end: Date) -> CalendarImportOptions {
        CalendarImportOptions(datePreset: .custom, customStartDate: start, customEndDate: end)
    }

    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }
}
