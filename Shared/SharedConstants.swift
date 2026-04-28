import Foundation

enum SharedConstants {
    static let appGroup = "group.dev.nostr.clave"
    static let keychainService = "dev.nostr.clave.shared"
    static let keychainAccount = "signer-nsec"
    static let relayURL = "wss://relay.powr.build"
    static let defaultProxyURL = "https://proxy.clave.casa"

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
    /// `Date.timeIntervalSince1970` of the most recent successful POST to
    /// `/register`. Used by `AppState.ensureRegisteredFresh()` to throttle
    /// opportunistic re-registers to ~30 min while still self-healing from
    /// silently-dropped network failures (audit follow-up 2026-04-28).
    static let lastRegisterSucceededAtKey = "lastRegisterSucceededAt"
    /// Same shape, for the most recent failed POST. Used to enforce a 60s
    /// cooldown between failed attempts so a dead proxy doesn't get hammered.
    static let lastRegisterFailedAtKey = "lastRegisterFailedAt"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroup)!
    }
}
