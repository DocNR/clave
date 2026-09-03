import Foundation

/// Single-slot, TTL-bounded persistence for a `nostrconnect://` connect URI
/// that arrived while the device had zero accounts (the brand-new-user "Sign
/// in with Clave" path). The URI survives the App Store round trip / key
/// creation so the partner request can be replayed once the user finishes
/// onboarding.
///
/// Semantics (spec §"The flows → C" + data-integrity rule):
/// - **Single-slot, last-writer-wins:** a newer connect URI overwrites and
///   scrubs an older one (secrets are single-use; the loser's partner retry
///   covers it).
/// - **TTL:** Phase 1 is always 10 minutes. An expired stash is scrubbed
///   *without* replay at promotion/peek time.
/// - **Scrub after replay:** `promote` clears the persisted slot as it hands
///   the URI to the in-memory replay, so a crash can't replay it twice.
/// - `createdDuringFlow` is NOT stored here (see `ParsedURI.CodingKeys`); it
///   is set on the in-memory payload at promotion time by the caller.
struct OnboardingConnectStash {

    /// Phase 1: always 10 minutes (URI `expiry=` arrives in Phase 2).
    static let ttl: TimeInterval = 10 * 60

    private let defaults: UserDefaults
    private let key = "onboardingConnectStash.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct Record: Codable {
        let parsed: NostrConnectParser.ParsedURI
        let storedAt: Double
    }

    /// Overwrite the single slot with `parsed` (last-writer-wins).
    func store(_ parsed: NostrConnectParser.ParsedURI, now: Double) {
        guard let data = try? JSONEncoder().encode(Record(parsed: parsed, storedAt: now)) else { return }
        defaults.set(data, forKey: key)
    }

    /// The stashed URI if one is present and unexpired; scrubs an expired
    /// slot as a side effect. Does NOT scrub a valid slot (the onboarding
    /// banner peeks repeatedly while the user is choosing generate/import).
    func peek(now: Double) -> NostrConnectParser.ParsedURI? {
        readValid(now: now)?.parsed
    }

    /// Consume the stash: returns the unexpired URI (and scrubs the slot), or
    /// nil if empty/expired (scrubbing an expired slot without replay).
    func promote(now: Double) -> NostrConnectParser.ParsedURI? {
        let record = readValid(now: now)
        clear() // scrub at promotion regardless: valid → after taking; expired already cleared
        return record?.parsed
    }

    /// Unconditionally scrub the slot.
    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Decode the slot; scrub-and-return-nil if missing, undecodable, or past
    /// the TTL. Boundary: exactly `ttl` seconds old is still valid (`>`).
    private func readValid(now: Double) -> Record? {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return nil
        }
        if now - record.storedAt > Self.ttl {
            clear()
            return nil
        }
        return record
    }
}
