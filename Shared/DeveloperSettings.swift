import Foundation
import Observation

@Observable
final class DeveloperSettings: @unchecked Sendable {
    static let shared = DeveloperSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let developerMenuUnlocked = "dev.nostr.clave.developerMenuUnlocked"
    }

    var developerMenuUnlocked: Bool {
        didSet { defaults.set(developerMenuUnlocked, forKey: Key.developerMenuUnlocked) }
    }

    init(defaults: UserDefaults = SharedConstants.sharedDefaults) {
        self.defaults = defaults
        self.developerMenuUnlocked = defaults.bool(forKey: Key.developerMenuUnlocked)
    }

    /// Pure helper: returns true if the most recent `required` timestamps all fall within `window` seconds of each other.
    /// Used by the tap-count-to-unlock gesture on the Version row.
    nonisolated static func tapGateSatisfied(timestamps: [Date], window: TimeInterval, required: Int) -> Bool {
        guard timestamps.count >= required else { return false }
        let recent = timestamps.suffix(required)
        guard let first = recent.first, let last = recent.last else { return false }
        return last.timeIntervalSince(first) <= window
    }
}
