import Foundation

enum SharedConstants {
    static let appGroup = "group.dev.nostr.clave"
    static let keychainService = "dev.nostr.clave.shared"
    static let keychainAccount = "signer-nsec"
    static let relayURL = "wss://relay.powr.build"

    // UserDefaults keys
    static let signerPubkeyHexKey = "signerPubkeyHex"
    static let clientPubkeyHexKey = "clientPubkeyHex"
    static let deviceTokenKey = "apnsDeviceToken"
    static let proxyURLKey = "proxyURL"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroup)!
    }
}
