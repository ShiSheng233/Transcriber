import Foundation
import Observation

/// The current settings, loaded from and saved to UserDefaults.
@Observable
final class SettingsStore {
    private static let defaultsKey = "AppSettings"
    private let userDefaults: UserDefaults

    private(set) var settings: AppSettings

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = .defaults
        }
    }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
