import Foundation

/// Outcome of a NostrConnect handshake invocation. In Phase 1 the array
/// is always 1-element (single signer); Phase 2 enables N > 1 for the
/// multi-account flow.
struct HandshakeResult: Equatable {

    struct FailedSigner: Equatable {
        let signerPubkey: String
        /// Human-readable error message captured at the point of failure.
        /// Stored as a String rather than `Error` so the result type is
        /// `Equatable` for test assertions.
        let errorMessage: String
    }

    let succeeded: [String]   // signer pubkeys that paired successfully
    let failed: [FailedSigner]

    var isAllSuccess: Bool { !succeeded.isEmpty && failed.isEmpty }
    var isAllFailure: Bool { succeeded.isEmpty && !failed.isEmpty }
    var isPartialFailure: Bool { !succeeded.isEmpty && !failed.isEmpty }
}
