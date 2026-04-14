import Foundation

enum SharedConstants {
    static let appGroup = "group.dev.nostr.clave"
    static let keychainService = "dev.nostr.clave.shared"
    static let keychainAccount = "signer-nsec"
    static let relayURL = "wss://relay.powr.build"
    static let defaultProxyURL = "https://proxy.clave.casa"
    static let proxyRegisterSecretKey = "proxyRegisterSecret"
    static let defaultProxyRegisterSecret = "9790fbe5278dbf7c0aa139a19e7c6e755f26ec1dcf55a63fa7649ac345bb1571" // TODO: replace with signed registration before App Store

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
    static let bunkerSecretKey = "bunkerSecret"
    static let pairedClientsKey = "pairedClients"
    static let cachedProfileKey = "cachedProfile"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroup)!
    }
}
