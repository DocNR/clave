import Foundation

enum SharedConstants {
    static let appGroup = "group.dev.nostr.clave"
    static let keychainService = "dev.nostr.clave.shared"
    static let keychainAccount = "signer-nsec"
    static let relayURL = "wss://relay.powr.build"
    // TEMP for feat/multi-account internal-TestFlight builds: points at the
    // parallel test proxy on Dell (port 3047), which has Stage A's
    // `signer_pubkey` payload field deployed. Production proxy (the
    // `proxy.clave.casa` URL) does NOT have Stage A yet — flipping back to
    // the prod URL is the LAST commit on this branch before merging to
    // main, after Stage A (#22) ships to production.
    static let defaultProxyURL = "https://proxy-test.clave.casa"

    // UserDefaults keys
    static let signerPubkeyHexKey = "signerPubkeyHex"
    static let clientPubkeyHexKey = "clientPubkeyHex"
    static let deviceTokenKey = "apnsDeviceToken"
    static let proxyURLKey = "proxyURL"
    static let activityLogKey = "activityLog"
    static let connectedClientsKey = "connectedClients"
    static let blockedKindsKey = "blockedKinds"
    static let autoSignKey = "autoSignEnabled"
    static let pendingRequestsKey = "pendingRequests"
    static let pendingPairOpsKey = "pendingPairOps"
    static let bunkerSecretKey = "bunkerSecret"
    static let pairedClientsKey = "pairedClients"
    static let clientPermissionsKey = "clientPermissions"
    static let cachedProfileKey = "cachedProfile"
    /// Snapshot of the user's last signed kind:3 contact-list pubkey set,
    /// stored as a JSON-encoded `[String]` (sorted hex pubkeys). Used by
    /// `ActivitySummary` to compute add/remove diffs on subsequent kind:3
    /// signs so the activity summary reads "Followed @alice" instead of
    /// "Followed 712 accounts". Skipped when the new kind:3 has >2000 p tags.
    static let lastContactSetKey = "lastContactSet"
    /// `Date.timeIntervalSince1970` of the most recent successful POST to
    /// `/register`. Used by `AppState.ensureRegisteredFresh()` to throttle
    /// opportunistic re-registers to ~30 min while still self-healing from
    /// silently-dropped network failures (audit follow-up 2026-04-28).
    static let lastRegisterSucceededAtKey = "lastRegisterSucceededAt"
    /// Same shape, for the most recent failed POST. Used to enforce a 60s
    /// cooldown between failed attempts so a dead proxy doesn't get hammered.
    static let lastRegisterFailedAtKey = "lastRegisterFailedAt"

    // MARK: - Multi-account keys (added 2026-04-30, feat/multi-account)
    //
    // These reserve the new UserDefaults namespace for multi-account state.
    // No callers wired up yet (Task 1 is pure additive); follow-up tasks
    // populate them. See ~/hq/clave/plans/2026-04-30-multi-account-sprint.md.

    /// JSON-encoded `[Account]` array — the user's identities. Source of
    /// truth for which accounts exist on this device. Pubkey is the foreign
    /// key linking to per-pubkey records in SharedStorage and Keychain.
    static let accountsKey = "accounts"

    /// Current account's signer pubkey hex. UI scope only — NSE never
    /// reads this for routing (NSE uses `signer_pubkey` from APNs payload).
    /// Replaces `signerPubkeyHexKey` semantically; the legacy key stays in
    /// sync as a write-through for callers that still read it during the
    /// transitional window.
    static let currentSignerPubkeyHexKey = "currentSignerPubkeyHex"

    /// JSON-encoded `[String: String]` mapping signer pubkey → bunker
    /// secret hex. Each account has its own secret rotated independently.
    /// Replaces the legacy global `bunkerSecretKey`.
    static let bunkerSecretsKey = "bunkerSecrets"

    /// JSON-encoded `[String: [String]]` mapping signer pubkey → sorted
    /// kind:3 contact pubkey list. Used by `ActivitySummary.signedSummary`
    /// to compute per-account follow add/remove diffs. Critical
    /// correctness: a global key would cross-contaminate account A's
    /// snapshot with account B's kind:3 sign, producing wildly wrong
    /// follow summaries.
    static let lastContactSetsKey = "lastContactSets"

    /// JSON-encoded `[String: [String: Double]]` (signer pubkey →
    /// `["succeeded": ts, "failed": ts]`). Per-account register throttle
    /// + cooldown. Replaces global `lastRegisterSucceededAtKey` /
    /// `lastRegisterFailedAtKey`.
    static let lastRegisterTimesKey = "lastRegisterTimes"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroup)!
    }
}
