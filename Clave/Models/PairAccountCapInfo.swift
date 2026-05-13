import Foundation

/// Cap pre-flight info for one account in the multi-select picker. Computed
/// at picker render time so capped accounts can be visually disabled with a
/// "5/5 clients" badge before the user commits to a multi-pair operation.
///
/// The cap (5 distinct paired clients per signer) is enforced server-side
/// by the proxy's `pair-client` endpoint. This struct is a client-side
/// view of the same constraint, used for UX-side surfacing only — the
/// proxy is the source of truth.
struct PairAccountCapInfo: Equatable {

    /// Maximum distinct paired clients per signer. Mirrors the proxy's
    /// `pair-client` enforcement.
    static let cap = 5

    let signerPubkey: String
    let currentPairCount: Int

    var isAtCap: Bool { currentPairCount >= Self.cap }
    var remaining: Int { max(0, Self.cap - currentPairCount) }
}
