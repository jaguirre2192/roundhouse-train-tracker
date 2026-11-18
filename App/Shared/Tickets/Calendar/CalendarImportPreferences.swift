import Foundation

@MainActor
struct CalendarImportPreferences {
    /// Posted after options are saved, so an open suggestions card rereads with them.
    static let didChange = Notification.Name("CalendarImportPreferences.didChange")

    private let defaults: UserDefaults?
    private let key: String

    /// Pass nil for previews and tests that should not read or write device preferences.
    init(defaults: UserDefaults? = .standard, key: String = "calendarImport.options.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// Previews and tests pass nil defaults; their in-memory options must not be reloaded.
    var isPersistent: Bool { defaults != nil }

    func load() -> CalendarImportOptions {
        guard let data = defaults?.data(forKey: key),
              let options = try? JSONDecoder().decode(CalendarImportOptions.self, from: data) else {
            return CalendarImportOptions()
        }
        return options
    }

    func save(_ options: CalendarImportOptions) throws {
        let data = try JSONEncoder().encode(options)
        defaults?.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
