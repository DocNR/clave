import Foundation

/// Navigation route to per-account detail. Used by HomeView's NavigationStack
/// from three origins: AccountStripView active-pill tap, AccountStripView
/// long-press, and SettingsView Accounts row tap.
enum AccountNavTarget: Hashable {
    case detail(pubkey: String)
}
