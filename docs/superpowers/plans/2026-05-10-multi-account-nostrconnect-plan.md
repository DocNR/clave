# Multi-Account NostrConnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the two-phase change specified in [`2026-05-10-multi-account-nostrconnect-design.md`](../specs/2026-05-10-multi-account-nostrconnect-design.md). Phase 1: promote Connect from a HomeView sheet to a top-level cross-account `MainTabView` tab; unify all account-binding consent through a single `ConnectAccountPicker`; refactor `handleNostrConnect` to an array-shaped signature with `HandshakeResult` (always 1-element in Phase 1). Phase 2: extend NIP-46 with an `accounts=multi` URI opt-in, multi-select picker mode, an N-up handshake loop, enriched JSON `result` field, partial-failure UX, and cap pre-flight.

**Architecture:** Phase 1 is a UX/IA refactor — no protocol changes, no Tableau dependency. Phase 2 layers the multi-account protocol opt-in on the foundation Phase 1 lays. Phases are independently mergeable as separate PRs; each phase ends in a clean, shippable state.

**Tech Stack:** Swift / SwiftUI on iOS, XCTest, existing Clave primitives (`AppState`, `SharedStorage`, `LightSigner`, `LightCrypto`, `LightEvent`, `NostrConnectParser`, `RelayUtils`). No new third-party deps.

**Branch:** `spec/multi-account-nostrconnect` (current). Implementation lands in **two PRs**, one per phase, each branching off `main` separately when ready — NOT off this spec branch. The spec/plan branch is the planning artifact; implementation branches reference it but rebase to main.

**Verification model:** Clave runs unit tests via Xcode/`xcodebuild` and verifies builds + tests pass per task. Manual smoke tests on real device at the end of each phase. Pre-commit hooks may enforce linting — do NOT skip them; if a hook fails, fix the underlying issue.

**Commit model:** Per-task commits within each phase (TDD-style: red → green → commit). Conventional-commits format matching the existing repo style: `feat(connect): ...`, `refactor(connect): ...`, `test(connect): ...`, etc. Each commit ends with the `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.

**Reading order:** Read the spec end-to-end before starting Task 1. Re-read the Phase 2 section before starting Phase 2 Task 1. The spec is authoritative for "why" decisions; this plan is authoritative for "how" sequencing.

---

## File structure

### Phase 1 — Connect entry restructure + picker unification

**Created:**
- `Clave/Views/Connect/ConnectTabView.swift` — the new tab root; hosts the NostrConnect surface + child route to bunker
- `Clave/Views/Connect/ConnectNostrConnectSurface.swift` — camera viewfinder + paste field + bunker secondary affordance (extracted from `ConnectNostrconnectTabView`)
- `Clave/Views/Connect/ConnectBunkerView.swift` — bunker child route: picker first, then URI render (extracted from `ConnectBunkerTabView`)
- `Clave/Views/Connect/ConnectAccountPicker.swift` — renamed from `DeeplinkAccountPicker`; gains `Mode` enum (single only in Phase 1); used by all 3 paths (in-app NostrConnect, in-app bunker, deeplink)
- `Clave/Models/HandshakeResult.swift` — new value type for the refactored `handleNostrConnect` return shape

**Modified:**
- `Clave/Views/MainTabView.swift` — add 4th tab item for Connect
- `Clave/AppState+NostrConnect.swift` — signature refactor: `boundAccountPubkey: String?` → `signerPubkeys: [String]`; returns `HandshakeResult`; iteration body wraps existing handshake (always 1 iteration in Phase 1)
- `Clave/Views/Home/HomeView.swift` — remove Connect-a-Client button + sheet trigger; replace empty-state CTA with text pointing at the Connect tab
- `Clave/ClaveApp.swift` — deeplink routing already uses `pendingDeeplinkAccountChoice`; verify it now feeds `ConnectAccountPicker` (rename references)
- `Clave/Views/Home/ApprovalSheet.swift` — accept `boundAccountPubkey: String` (was inferred); call site change

**Deleted:**
- `Clave/Views/Home/Connect/ConnectSheet.swift` — contents move into `ConnectTabView`
- `Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift` — contents move into `ConnectNostrConnectSurface`
- `Clave/Views/Home/Connect/ConnectBunkerTabView.swift` — contents move into `ConnectBunkerView`
- `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift` — renamed to `ConnectAccountPicker`
- `Clave/Views/Home/Connect/` directory (after all files moved)
- The `ConnectAccountContextBar` reference in `ConnectSheet.swift:41` — function replaced by picker step

**Test files created:**
- `ClaveTests/HandshakeResultTests.swift` — value-type smoke
- `ClaveTests/ConnectAccountPickerAutoSkipTests.swift` — auto-skip behavior at N=1, present at N≥2
- `ClaveTests/AppStateHandshakeSignatureTests.swift` — array-signature contract; always-1-element behavior identical to today

### Phase 2 — Multi-account NostrConnect protocol opt-in

**Created:**
- `Clave/Views/Connect/MultiPairProgressView.swift` — the in-loop progress UI fragment (succeeded/current/queued row states)
- `Clave/Views/Connect/MultiPairResultView.swift` — post-loop summary (success / mixed / all-failure variants)
- `Clave/Models/PairAccountCapInfo.swift` — small value type carrying `(signerPubkey, currentPairCount, isAtCap)` for picker pre-flight

**Modified:**
- `Clave/Shared/NostrConnectParser.swift` — add `isMultiAccount: Bool` field; parse from `accounts=multi` query param
- `Clave/Views/Connect/ConnectAccountPicker.swift` — implement `.multi` case (checkboxes, default selection rules, cap-disabled rows, "Continue with N accounts" button)
- `Clave/Views/Home/ApprovalSheet.swift` — multi-mode header + selected-account inline list + "Approve N accounts" button; progress + result sub-views
- `Clave/AppState+NostrConnect.swift` — enable N>1 path; cap-disabled signers skipped before loop; `HandshakeResult.failed` populated correctly; per-iteration progress callback
- `Clave/Shared/LightSigner.swift` — emit enriched JSON `result` (`{echoed_secret, name, picture}`) for multi-account acks only; single-account flow keeps existing string-secret response
- `Clave/Shared/SharedStorage.swift` — add `pairCountForSigner(_ signer: String) -> Int` helper (computed from existing `getConnectedClients(for:)`)
- `Clave/docs/integrations.md` — document `accounts=multi` URI param, listening-window expectation, JSON `result` shape
- `Clave/docs/nip46-compatibility.md` — add "Multi-account NostrConnect" column to client matrix

**Test files created:**
- `ClaveTests/NostrConnectParserMultiAccountTests.swift` — extends `NostrConnectParserTests` for the new flag
- `ClaveTests/AppStateMultiAccountHandshakeTests.swift` — N-up loop semantics: all-success, partial, all-failure paths; `HandshakeResult` correctness
- `ClaveTests/ConnectAccountPickerMultiModeTests.swift` — multi-mode rendering, cap pre-flight disable, default-selection rules
- `ClaveTests/LightSignerMultiAccountResultTests.swift` — JSON result emission for multi-account; bare-string response preserved for single-account
- `ClaveTests/PairAccountCapInfoTests.swift` — cap value-type

---

## Phase 1 — Connect entry restructure + picker unification

**Goal of this phase:** ship a self-contained UX/IA refactor. After Phase 1, the user experience changes (Connect is its own tab; account binding is explicit on every entry path), but the wire protocol is unchanged. A single-account user sees no functional change.

**Estimated total tasks:** 14.

**Phase 1 acceptance criteria** (from spec, lines 408-414):
- Connect tab present in `MainTabView`, opens to NostrConnect-primary surface
- Bunker secondary affordance pushes to bunker view, picker fires before URI render (auto-skipped for N=1)
- NostrConnect paste/scan routes through `ConnectAccountPicker` (single-select), then `ApprovalSheet`, exactly as deeplink does today
- HomeView no longer presents `ConnectSheet`; the old button is gone
- All existing tests pass; no regressions in existing NostrConnect / bunker flows
- Smoke test on real device: pair a client to each of 2+ accounts via the new tab; pair via the deeplink path; bunker URI render for non-current account works without first switching identity bar

### Task 1: Add `HandshakeResult` value type

**Files:**
- Create: `Clave/Models/HandshakeResult.swift`
- Test: `ClaveTests/HandshakeResultTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/HandshakeResultTests.swift`:

```swift
import XCTest
@testable import Clave

final class HandshakeResultTests: XCTestCase {

    func testEmptyResult() {
        let r = HandshakeResult(succeeded: [], failed: [])
        XCTAssertEqual(r.succeeded.count, 0)
        XCTAssertEqual(r.failed.count, 0)
        XCTAssertFalse(r.isPartialFailure)
        XCTAssertTrue(r.isAllSuccess)
        XCTAssertFalse(r.isAllFailure)
    }

    func testAllSuccess() {
        let r = HandshakeResult(succeeded: ["pk1", "pk2"], failed: [])
        XCTAssertTrue(r.isAllSuccess)
        XCTAssertFalse(r.isPartialFailure)
        XCTAssertFalse(r.isAllFailure)
    }

    func testPartialFailure() {
        let r = HandshakeResult(
            succeeded: ["pk1"],
            failed: [HandshakeResult.FailedSigner(signerPubkey: "pk2", errorMessage: "cap exceeded")]
        )
        XCTAssertFalse(r.isAllSuccess)
        XCTAssertTrue(r.isPartialFailure)
        XCTAssertFalse(r.isAllFailure)
    }

    func testAllFailure() {
        let r = HandshakeResult(
            succeeded: [],
            failed: [
                HandshakeResult.FailedSigner(signerPubkey: "pk1", errorMessage: "relay down"),
                HandshakeResult.FailedSigner(signerPubkey: "pk2", errorMessage: "relay down")
            ]
        )
        XCTAssertFalse(r.isAllSuccess)
        XCTAssertFalse(r.isPartialFailure)
        XCTAssertTrue(r.isAllFailure)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/HandshakeResultTests 2>&1 | tail -20`

Expected: build FAILS with `cannot find 'HandshakeResult' in scope`.

- [ ] **Step 3: Create the type**

Create `Clave/Models/HandshakeResult.swift`:

```swift
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
```

- [ ] **Step 4: Add the file to the Xcode project**

The project auto-syncs files under `Clave/` per the AppState refactor sprint notes — verify by running:

`xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS. If `HandshakeResult.swift` doesn't resolve, add it to the Clave target in the Xcode project file manually.

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/HandshakeResultTests 2>&1 | tail -20`

Expected: 4 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/danielwyler/clave/Clave
git add Clave/Models/HandshakeResult.swift ClaveTests/HandshakeResultTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): add HandshakeResult value type

Phase 1 of multi-account NostrConnect. New return type for the
refactored handleNostrConnect signature: tracks succeeded + failed
signer pubkeys with derived isAllSuccess / isAllFailure /
isPartialFailure conveniences. FailedSigner stores error as String
for Equatable conformance (tests).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2: Refactor `handleNostrConnect` to array signature

**Files:**
- Modify: `Clave/AppState+NostrConnect.swift`
- Test: `ClaveTests/AppStateHandshakeSignatureTests.swift`

This task changes the function signature without changing behavior. Callers will be updated in Task 12; tests verify the new contract.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/AppStateHandshakeSignatureTests.swift`:

```swift
import XCTest
@testable import Clave

/// Phase 1 verifies the array-signature refactor preserves single-account
/// behavior. The actual handshake invocation is impractical to unit-test
/// (requires live relays), so these tests assert the signature shape and
/// the always-1-element semantics by inspection.
final class AppStateHandshakeSignatureTests: XCTestCase {

    /// Smoke: the signature is `(parsedURI:, signerPubkeys:, permissions:)
    /// async throws -> HandshakeResult`. If this compiles, the contract holds.
    func testHandleNostrConnectSignatureCompiles() {
        let _: (NostrConnectParser.ParsedURI, [String], ClientPermissions) async throws -> HandshakeResult =
            { (uri, pks, perms) in
                let appState = AppState()
                return try await appState.handleNostrConnect(
                    parsedURI: uri,
                    signerPubkeys: pks,
                    permissions: perms
                )
            }
    }

    /// Empty signerPubkeys array is rejected at the boundary, not silently
    /// dropped. Phase 1 always passes 1 element; future-proofing against
    /// Phase 2 misuse.
    func testEmptySignerPubkeysThrows() async throws {
        let appState = await AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://abc?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "abc",
            signerPubkeyHex: "",
            permissions: [],
            name: nil,
            addedAt: Date().timeIntervalSince1970
        )
        do {
            _ = try await appState.handleNostrConnect(
                parsedURI: dummyURI,
                signerPubkeys: [],
                permissions: perms
            )
            XCTFail("Expected ClaveError.noSignerKey for empty signerPubkeys")
        } catch ClaveError.noSignerKey {
            // expected
        } catch {
            XCTFail("Expected ClaveError.noSignerKey, got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/AppStateHandshakeSignatureTests 2>&1 | tail -30`

Expected: build FAILS with `argument 'signerPubkeys' not found` or similar — the current signature has `boundAccountPubkey: String?` not `signerPubkeys: [String]`.

- [ ] **Step 3: Refactor `handleNostrConnect` to the array signature**

In `Clave/AppState+NostrConnect.swift`, replace the existing `handleNostrConnect` function (lines 31-179) with:

```swift
    /// Perform the nostrconnect:// handshake for each signer in `signerPubkeys`.
    /// In Phase 1 this is always 1-element. Phase 2 enables N > 1 for the
    /// multi-account flow — each iteration runs the same handshake with a
    /// different signer's nsec.
    ///
    /// Why multi-relay per iteration: the client (per NIP-46) subscribes on
    /// every relay in its URI; if we publish to only one and that relay drops
    /// the ephemeral kind:24133, the client never sees our response. Publishing
    /// to all is best-effort — we don't fail if some relays reject or are
    /// unreachable, we just need at least one.
    @discardableResult
    func handleNostrConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        signerPubkeys: [String],
        permissions: ClientPermissions
    ) async throws -> HandshakeResult {
        guard !signerPubkeys.isEmpty else {
            throw ClaveError.noSignerKey
        }

        var succeeded: [String] = []
        var failed: [HandshakeResult.FailedSigner] = []

        for signerPubkey in signerPubkeys {
            do {
                try await runSingleConnect(
                    parsedURI: parsedURI,
                    signerPubkey: signerPubkey,
                    permissions: permissions
                )
                succeeded.append(signerPubkey)
            } catch {
                failed.append(HandshakeResult.FailedSigner(
                    signerPubkey: signerPubkey,
                    errorMessage: error.localizedDescription
                ))
            }
        }

        return HandshakeResult(succeeded: succeeded, failed: failed)
    }

    /// One signer's handshake — body is the pre-refactor handleNostrConnect
    /// with `boundAccountPubkey` replaced by the explicit `signerPubkey`
    /// argument. Phase 2 calls this inside a loop; Phase 1 calls it once.
    private func runSingleConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        signerPubkey resolvedSignerPubkey: String,
        permissions: ClientPermissions
    ) async throws {
        guard !resolvedSignerPubkey.isEmpty,
              let nsec = SharedKeychain.loadNsec(for: resolvedSignerPubkey) else {
            throw ClaveError.noSignerKey
        }
        let privateKey = try Bech32.decodeNsec(nsec)
        let signerPubkey = try LightEvent.pubkeyHex(from: privateKey)

        // Save client permissions
        SharedStorage.saveClientPermissions(permissions)

        guard !parsedURI.relays.isEmpty else {
            throw ClaveError.noRelay
        }
        guard let clientPubkeyData = Data(hexString: parsedURI.clientPubkey) else {
            throw ClaveError.invalidPubkey
        }

        // Connect to every URI relay in parallel, best-effort.
        let connectedRelays = await RelayUtils.connectToRelays(urls: parsedURI.relays, timeout: 10.0)
        defer {
            for relay in connectedRelays { relay.disconnect() }
        }

        if connectedRelays.isEmpty {
            let entry = ActivityEntry(
                id: UUID().uuidString,
                method: "connect",
                eventKind: nil,
                clientPubkey: parsedURI.clientPubkey,
                timestamp: Date().timeIntervalSince1970,
                status: "error",
                errorMessage: "Could not connect to any relay",
                signerPubkeyHex: signerPubkey
            )
            SharedStorage.logActivity(entry)
            throw ClaveError.noRelay
        }

        var handshakeComplete = false
        var activityLogged = false
        var seenEventIds = Set<String>()

        for _ in 1...3 {
            let responseId = UUID().uuidString
            let responseDict: [String: Any] = ["id": responseId, "result": parsedURI.secret]
            guard let responseData = try? JSONSerialization.data(withJSONObject: responseDict),
                  let responseJSON = String(data: responseData, encoding: .utf8) else {
                continue
            }
            let freshEncrypted = try LightCrypto.nip44Encrypt(
                privateKey: privateKey,
                publicKey: clientPubkeyData,
                plaintext: responseJSON
            )
            let connectEvent = try LightEvent.sign(
                privateKey: privateKey,
                kind: 24133,
                content: freshEncrypted,
                tags: [["p", parsedURI.clientPubkey]]
            )

            if !handshakeComplete,
               let eventData = connectEvent.toJSON().data(using: .utf8),
               let eventDict = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] {
                let acceptedCount = await RelayUtils.publishEventToRelays(connectedRelays, event: eventDict)

                if !activityLogged {
                    let success = acceptedCount > 0
                    let entry = ActivityEntry(
                        id: UUID().uuidString,
                        method: "connect",
                        eventKind: nil,
                        clientPubkey: parsedURI.clientPubkey,
                        timestamp: Date().timeIntervalSince1970,
                        status: success ? "signed" : "error",
                        errorMessage: success ? nil : "All relays rejected connect response",
                        signerPubkeyHex: signerPubkey
                    )
                    SharedStorage.logActivity(entry)
                    activityLogged = true

                    if success {
                        pairClientWithProxy(
                            clientPubkey: parsedURI.clientPubkey,
                            relayUrls: parsedURI.relays,
                            signer: signerPubkey
                        )
                    } else {
                        throw ClaveError.noRelay
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let now = Int(Date().timeIntervalSince1970)
            let listenFilter: [String: Any] = [
                "kinds": [24133],
                "#p": [signerPubkey],
                "since": now - 10,
                "limit": 10
            ]
            let events = await RelayUtils.fetchEventsFromRelays(connectedRelays, filter: listenFilter, timeout: 3.0)
            for event in events {
                guard let eventId = event["id"] as? String, seenEventIds.insert(eventId).inserted else { continue }
                guard let pubkey = event["pubkey"] as? String,
                      pubkey == parsedURI.clientPubkey else { continue }
                let _ = try? await LightSigner.handleRequest(
                    privateKey: privateKey,
                    requestEvent: event,
                    responseRelays: connectedRelays
                )
                handshakeComplete = true
            }
        }
    }
```

Key changes from the existing function:
1. Public function is the N-up loop wrapper (always 1 iteration in Phase 1)
2. Body of the existing function moved into private `runSingleConnect` helper
3. `boundAccountPubkey: String?` parameter replaced by explicit `signerPubkey` on the helper
4. Public function returns `HandshakeResult`
5. The success branch throws if `acceptedCount == 0` so the iteration is counted as a failure in `HandshakeResult.failed`

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/AppStateHandshakeSignatureTests 2>&1 | tail -30`

Expected: 2 tests, both PASS.

- [ ] **Step 5: Update all callers of `handleNostrConnect`**

Find them:

```bash
cd /Users/danielwyler/clave/Clave && grep -rn "handleNostrConnect" Clave ClaveTests --include="*.swift"
```

Expected callers (verify before editing):
- `Clave/Views/Home/Connect/ConnectSheet.swift` (will be deleted in Task 11)
- `Clave/ClaveApp.swift` (deeplink path)
- Any others surfaced by grep

For each caller, replace:
```swift
try await appState.handleNostrConnect(
    parsedURI: captured,
    permissions: capturedPerms
)
```
With:
```swift
let result = try await appState.handleNostrConnect(
    parsedURI: captured,
    signerPubkeys: [boundAccountPubkey],
    permissions: capturedPerms
)
// Single-account flow: result.succeeded.count is 1 on success.
// If empty, the inner throw propagated and we never reach this line.
```

The `boundAccountPubkey` variable resolution depends on the caller — pull from the deeplink picker, from `appState.currentAccount?.pubkeyHex`, or from the in-flight URI's bound account as appropriate at each call site.

- [ ] **Step 6: Build to verify all callers compile**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20`

Expected: build SUCCEEDS.

- [ ] **Step 7: Run the full test suite to catch any regressions**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -30`

Expected: all 28+ test files PASS (the count was 28 at plan-write time; verify no regressions).

- [ ] **Step 8: Commit**

```bash
git add Clave/AppState+NostrConnect.swift \
        ClaveTests/AppStateHandshakeSignatureTests.swift \
        Clave/Views/Home/Connect/ConnectSheet.swift \
        Clave/ClaveApp.swift
# Plus any other call-site files updated in Step 5.
git commit -m "$(cat <<'EOF'
refactor(connect): handleNostrConnect → array signature + HandshakeResult

Phase 1 of multi-account NostrConnect. Refactors handleNostrConnect
from `(parsedURI:, permissions:, boundAccountPubkey:)` to
`(parsedURI:, signerPubkeys:, permissions:) → HandshakeResult`. The
implementation iterates over the array; Phase 1 always passes
exactly 1 element so behavior is identical to today.

Body of the existing function moves into a private runSingleConnect
helper that takes the single signer pubkey explicitly. The public
function is the iteration wrapper that collects per-signer success
/ failure into HandshakeResult.

All known call sites updated to pass a 1-element array. Empty
signerPubkeys throws ClaveError.noSignerKey at the boundary.

No protocol change; pure refactor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3: Move and rename `DeeplinkAccountPicker` → `ConnectAccountPicker`

**Files:**
- Create: `Clave/Views/Connect/ConnectAccountPicker.swift`
- Delete: `Clave/Views/Home/Connect/DeeplinkAccountPicker.swift`

- [ ] **Step 1: Create the new `Connect` directory**

```bash
mkdir -p /Users/danielwyler/clave/Clave/Clave/Views/Connect
```

- [ ] **Step 2: Copy and adapt the file**

Create `Clave/Views/Connect/ConnectAccountPicker.swift`:

```swift
import SwiftUI

/// Unified account picker for all connect-time consent. Used by:
///   1. Phase 1 in-app NostrConnect flow (after URI parse, before ApprovalSheet)
///   2. Phase 1 in-app bunker flow (before URI render)
///   3. External nostrconnect:// deeplink flow (after URL routes in)
///
/// Mode `.single` is the only mode in Phase 1. Mode `.multi` lands in Phase 2
/// for multi-account NostrConnect. Auto-skips entirely when
/// `appState.accounts.count == 1` — the single account is auto-bound and the
/// picker never renders.
struct ConnectAccountPicker: View {

    enum Mode {
        case single   // bunker, single-NostrConnect, deeplink
        case multi    // Phase 2: NostrConnect with accounts=multi
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let parsedURI: NostrConnectParser.ParsedURI?  // nil for bunker (no URI yet)
    let onPick: (_ pubkeys: [String]) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                    .padding(.horizontal)
                    .padding(.top, 8)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.accounts) { account in
                            accountRow(for: account)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color(.systemGroupedBackground))
        .snapshotProtected()
    }

    private var navigationTitle: String {
        switch mode {
        case .single: return "Connect with which account?"
        case .multi: return "Connect with which accounts?"
        }
    }

    private var headerBlock: some View {
        Text(headerText)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
    }

    private var headerText: AttributedString {
        switch mode {
        case .single:
            // Phase 1 single-mode header — matches today's DeeplinkAccountPicker.
            var s = AttributedString("Choose the identity to use for ")
            var bold = AttributedString(clientLabel)
            bold.font = .system(size: 14, weight: .semibold)
            s.append(bold)
            s.append(AttributedString("."))
            return s
        case .multi:
            // Phase 2 multi-mode header.
            var s = AttributedString("\(clientLabel) wants to connect to multiple accounts.")
            return s
        }
    }

    private var clientLabel: String {
        parsedURI?.name ?? "this connection"
    }

    private func accountRow(for account: Account) -> some View {
        // Single-mode: tap-to-pick (radio behavior).
        // Multi-mode rendering lands in Phase 2 (Task 16). For now, .multi
        // falls back to the same tap-to-pick row so the Mode enum compiles
        // without Phase 2 changes.
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        let isCurrent = account.pubkeyHex == appState.currentAccount?.pubkeyHex
        return Button {
            onPick([account.pubkeyHex])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    if isCurrent {
                        Circle()
                            .fill(LinearGradient(colors: [theme.start, theme.end],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: 68, height: 68)
                    }
                    AvatarView(pubkeyHex: account.pubkeyHex,
                               name: account.displayLabel,
                               size: 60)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(account.displayLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(String(account.pubkeyHex.prefix(12)) + "…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.caption2.bold())
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.start.opacity(0.15), in: Capsule())
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
```

Note: `onPick` takes `[String]` (matches the array signature of `handleNostrConnect`). In `.single` mode it's always a 1-element array.

- [ ] **Step 3: Delete the old file**

```bash
cd /Users/danielwyler/clave/Clave
git rm Clave/Views/Home/Connect/DeeplinkAccountPicker.swift
```

- [ ] **Step 4: Update all references**

Find them:

```bash
grep -rn "DeeplinkAccountPicker" Clave ClaveTests --include="*.swift"
```

Replace each `DeeplinkAccountPicker(...)` call site with `ConnectAccountPicker(mode: .single, parsedURI: ..., onPick: ...)`. The old picker passed a single `String` to `onPick`; the new one passes `[String]` — call sites that took the first element from the closure need to adapt:

Before:
```swift
DeeplinkAccountPicker(parsedURI: uri) { pubkey in
    // pubkey: String
}
```

After:
```swift
ConnectAccountPicker(mode: .single, parsedURI: uri) { pubkeys in
    let pubkey = pubkeys[0]  // .single mode always 1-element
    // ...
}
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 6: Run full test suite**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -20`

Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Clave/Views/Connect/ConnectAccountPicker.swift
# Plus call-site files updated in Step 4
git commit -m "$(cat <<'EOF'
refactor(connect): rename DeeplinkAccountPicker → ConnectAccountPicker

Phase 1 of multi-account NostrConnect. The deeplink picker becomes
the unified account-binding component used by all connect entry
paths: in-app NostrConnect (Task 9), in-app bunker (Task 7), and
external deeplinks (this rename's primary call site). Picker gains
a Mode enum — only .single is implemented in Phase 1; .multi lands
in Phase 2.

onPick changes from `(String) -> Void` to `([String]) -> Void` to
match handleNostrConnect's array signature. Single mode always
passes a 1-element array.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4: Add auto-skip-when-N=1 behavior

**Files:**
- Modify: `Clave/Views/Connect/ConnectAccountPicker.swift`
- Test: `ClaveTests/ConnectAccountPickerAutoSkipTests.swift`

The picker should never render when only 1 account exists — auto-skip and call `onPick` directly with that account.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/ConnectAccountPickerAutoSkipTests.swift`:

```swift
import XCTest
@testable import Clave

/// The auto-skip rule is a static predicate so it can be checked at the
/// presenter level (parent view decides whether to present the picker at
/// all). Tests verify the predicate directly.
final class ConnectAccountPickerAutoSkipTests: XCTestCase {

    func testShouldSkipWhenSingleAccount() {
        XCTAssertTrue(ConnectAccountPicker.shouldAutoSkip(accountCount: 1))
    }

    func testShouldNotSkipWhenMultipleAccounts() {
        XCTAssertFalse(ConnectAccountPicker.shouldAutoSkip(accountCount: 2))
        XCTAssertFalse(ConnectAccountPicker.shouldAutoSkip(accountCount: 5))
    }

    func testShouldNotSkipWhenZeroAccounts() {
        // Edge case: zero accounts means no picker target. Caller should
        // route to onboarding; picker should NOT skip and auto-bind (there's
        // nothing to bind to).
        XCTAssertFalse(ConnectAccountPicker.shouldAutoSkip(accountCount: 0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/ConnectAccountPickerAutoSkipTests 2>&1 | tail -10`

Expected: build FAILS with `type 'ConnectAccountPicker' has no member 'shouldAutoSkip'`.

- [ ] **Step 3: Add the static predicate**

In `Clave/Views/Connect/ConnectAccountPicker.swift`, add this static method inside the struct:

```swift
    /// Whether the picker should be entirely skipped given the user's account
    /// count. Caller pattern: check this BEFORE presenting the picker; if true,
    /// call onPick directly with the sole account's pubkey instead of rendering
    /// the picker UI.
    ///
    /// Skip when exactly 1 account exists (the single-account case where
    /// the picker would be a degenerate one-row sheet). Do NOT skip when 0
    /// accounts exist — the caller should route to onboarding rather than
    /// auto-binding to a non-existent account.
    static func shouldAutoSkip(accountCount: Int) -> Bool {
        accountCount == 1
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/ConnectAccountPickerAutoSkipTests 2>&1 | tail -10`

Expected: 3 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add Clave/Views/Connect/ConnectAccountPicker.swift ClaveTests/ConnectAccountPickerAutoSkipTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): ConnectAccountPicker.shouldAutoSkip predicate

Phase 1 of multi-account NostrConnect. Static predicate the caller
checks BEFORE presenting the picker — when true, the caller calls
onPick directly with the single account's pubkey rather than
rendering a degenerate one-row sheet.

Skip rule: accountCount == 1. Zero accounts is NOT skipped (caller
routes to onboarding); 2+ accounts presents normally.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5: Create `ConnectNostrConnectSurface`

**Files:**
- Create: `Clave/Views/Connect/ConnectNostrConnectSurface.swift`
- (No tests — pure SwiftUI rendering; verified in smoke test at end of Phase 1)

Move the camera viewfinder + paste field + help link from `ConnectNostrconnectTabView` into the new file. The bunker-secondary affordance is added at the bottom.

- [ ] **Step 1: Create the new file**

Read the existing `Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift` (already in this plan's context — 284 lines). Create `Clave/Views/Connect/ConnectNostrConnectSurface.swift` with the contents of `ConnectNostrconnectTabView` PLUS the bunker secondary affordance.

```swift
import SwiftUI
import AVFoundation

/// The primary surface inside the Connect tab. Hosts:
///   - QR scanner viewfinder (when camera authorized)
///   - Paste-from-clipboard button + URI text field
///   - "What's a nostrconnect URI?" help link
///   - "Or share a code from Clave →" secondary affordance pushing to bunker view
///
/// Direct lift from the pre-existing ConnectNostrconnectTabView (now deleted
/// in Task 11). Camera permission handling, scan deduplication, and paste
/// validation are unchanged — verbatim copy.
struct ConnectNostrConnectSurface: View {

    /// Bound by parent (ConnectTabView). Triggers presentation of
    /// ConnectAccountPicker → ApprovalSheet.
    let parsedURI: NostrConnectParser.ParsedURI?
    let onParsed: (NostrConnectParser.ParsedURI, NostrConnectURISource) -> Void
    let onShowBunker: () -> Void

    @State private var pasteText = ""
    @State private var pasteError: String?
    @State private var showHelp = false
    @State private var cameraAuthState: AVAuthorizationStatus = .notDetermined
    @State private var isScanning = true
    @State private var scanError: String?
    @State private var lastAcceptedScanCode: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cameraSection
                pasteSection
                helpLink
                Divider()
                    .padding(.vertical, 8)
                bunkerSecondaryAffordance
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .onAppear {
            cameraAuthState = AVCaptureDevice.authorizationStatus(for: .video)
            if cameraAuthState == .notDetermined {
                Task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    await MainActor.run {
                        cameraAuthState = granted ? .authorized : .denied
                    }
                }
            }
        }
        .sheet(isPresented: $showHelp) {
            ConnectHelpSheet()
        }
        .onChange(of: parsedURI?.id) { _, newId in
            if newId == nil {
                isScanning = true
                scanError = nil
            }
        }
    }

    // MARK: - Camera section
    // (Copy verbatim from the deleted ConnectNostrconnectTabView lines 92-163)
    @ViewBuilder
    private var cameraSection: some View {
        switch cameraAuthState {
        case .authorized:
            ZStack {
                QRScannerView(
                    isScanning: isScanning,
                    onCode: handleScannedCode,
                    onPermissionDenied: { cameraAuthState = .denied }
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let scanError {
                    VStack {
                        Spacer()
                        Text(scanError)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        case .denied, .restricted:
            cameraDeniedPlaceholder
        case .notDetermined:
            cameraRequestingPlaceholder
        @unknown default:
            cameraDeniedPlaceholder
        }
    }

    private var cameraDeniedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Camera access denied")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var cameraRequestingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Requesting camera access…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paste section
    // (Copy verbatim from the deleted ConnectNostrconnectTabView lines 165-205)
    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or paste a URI")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste Nostrconnect URI", systemImage: "doc.on.clipboard")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            TextField("nostrconnect://...", text: $pasteText)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .submitLabel(.go)
                .padding(10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(pasteError == nil ? Color(.separator) : Color.red, lineWidth: 1)
                )
                .onSubmit { validateAndSubmit() }
                .onChange(of: pasteText) { _, _ in
                    if pasteError != nil { pasteError = nil }
                }
            if let pasteError {
                Text(pasteError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var helpLink: some View {
        Button {
            showHelp = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("What's a nostrconnect URI?")
            }
            .font(.subheadline)
            .fontWeight(.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.top, 4)
    }

    // MARK: - Bunker secondary affordance (NEW in this task)

    private var bunkerSecondaryAffordance: some View {
        Button {
            onShowBunker()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Or share a code from Clave")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Use Clave as your signer in another app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Validation + scan handling
    // (Copy verbatim from the deleted ConnectNostrconnectTabView lines 222-283)

    private func validateAndSubmit() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let parsed = try NostrConnectParser.parse(trimmed)
            pasteError = nil
            onParsed(parsed, .paste)
        } catch {
            pasteError = "That doesn't look like a valid nostrconnect URI."
        }
    }

    private func pasteFromClipboard() {
        guard let clipboard = UIPasteboard.general.string,
              !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pasteError = "Clipboard is empty."
            return
        }
        pasteText = clipboard
        validateAndSubmit()
    }

    private func handleScannedCode(_ code: String) {
        guard isScanning else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == lastAcceptedScanCode { return }
        do {
            let parsed = try NostrConnectParser.parse(trimmed)
            isScanning = false
            lastAcceptedScanCode = trimmed
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onParsed(parsed, .qrScan)
        } catch let error as NostrConnectParser.ParseError {
            switch error {
            case .invalidScheme: scanError = "Not a Nostrconnect code"
            case .missingPubkey: scanError = "Missing client public key"
            case .missingRelay:  scanError = "Missing relay parameter"
            case .missingSecret: scanError = "Missing secret parameter"
            case .invalidURL:    scanError = "Invalid URI format"
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if scanError != nil { scanError = nil }
            }
        } catch {
            scanError = "Couldn't parse code"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { scanError = nil }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS. The new file references `NostrConnectURISource` which still lives in the old `ConnectNostrconnectTabView.swift` — that's fine; the import resolves until Task 11 deletes the old file.

- [ ] **Step 3: Commit**

```bash
git add Clave/Views/Connect/ConnectNostrConnectSurface.swift
git commit -m "$(cat <<'EOF'
feat(connect): add ConnectNostrConnectSurface view

Phase 1 of multi-account NostrConnect. The primary surface inside
the new Connect tab — camera viewfinder + paste field + help link,
plus a new "Or share a code from Clave →" secondary affordance at
the bottom that pushes into the bunker view (Task 6).

Camera, paste, scan dedup, and validation logic are direct copies
of the to-be-deleted ConnectNostrconnectTabView (Task 11). The
bunker affordance is new — implements UX shape γ per the spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6: Create `ConnectBunkerView`

**Files:**
- Create: `Clave/Views/Connect/ConnectBunkerView.swift`

Wraps the existing `ConnectBunkerTabView` content but presents `ConnectAccountPicker` first (when N ≥ 2) before rendering the bunker URI for the selected account.

- [ ] **Step 1: Read the existing `ConnectBunkerTabView`**

Run `cat /Users/danielwyler/clave/Clave/Clave/Views/Home/Connect/ConnectBunkerTabView.swift` to see the existing implementation. This task wraps it in an account-picker step.

- [ ] **Step 2: Create the wrapper view**

Create `Clave/Views/Connect/ConnectBunkerView.swift`:

```swift
import SwiftUI

/// Bunker child route inside the Connect tab. The user has tapped the
/// "Or share a code from Clave →" affordance on the NostrConnect surface
/// and arrived here. Flow:
///   1. If accounts.count >= 2, present ConnectAccountPicker first
///   2. User picks the account for the bunker URI
///   3. Render the bunker URI + QR for that account
///   4. If accounts.count == 1, auto-skip the picker and render directly
struct ConnectBunkerView: View {

    @Environment(AppState.self) private var appState

    @State private var pickedSignerPubkey: String?
    @State private var showPicker = false

    var body: some View {
        Group {
            if let signer = pickedSignerPubkey {
                // Picker complete — render the bunker URI + QR for `signer`.
                // (Existing ConnectBunkerTabView content factored to take a
                // signer pubkey parameter — see Step 3.)
                BunkerURIRender(signerPubkey: signer)
            } else {
                // Initial state — present picker if N >= 2; else auto-skip.
                Color.clear
                    .onAppear { presentOrAutoSkip() }
                    .sheet(isPresented: $showPicker) {
                        ConnectAccountPicker(mode: .single, parsedURI: nil) { pubkeys in
                            pickedSignerPubkey = pubkeys.first
                            showPicker = false
                        }
                    }
            }
        }
        .navigationTitle("Share Bunker Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func presentOrAutoSkip() {
        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            pickedSignerPubkey = only.pubkeyHex
        } else {
            showPicker = true
        }
    }
}
```

- [ ] **Step 3: Extract `BunkerURIRender` from `ConnectBunkerTabView`**

The current `ConnectBunkerTabView` reads `appState.bunkerURI` directly, which is the current-account's bunker URI. We need a variant that takes a `signerPubkey` parameter and renders the bunker URI for THAT signer specifically — not whichever happens to be current.

Read `Clave/Views/Home/Connect/ConnectBunkerTabView.swift` end-to-end. Create `Clave/Views/Connect/BunkerURIRender.swift` (or in-line in `ConnectBunkerView.swift` if it's short) with the bunker URI/QR rendering content scoped to a specific signer.

Bunker URI generation for a specific signer:

```swift
struct BunkerURIRender: View {

    @Environment(AppState.self) private var appState

    let signerPubkey: String

    private var bunkerURI: String {
        // Pull the bunker URI for this specific signer. The existing
        // bunker URI generation uses appState.bunkerURI which is current-
        // account-scoped. For Phase 1 we need a per-signer variant.
        //
        // Existing pattern: AppState.bunkerURI computes
        //   "bunker://" + signerPubkeyHex + "?relay=" + relays + "&secret=" + bunkerSecret
        //
        // Per-signer variant: same shape, but signerPubkeyHex and bunkerSecret
        // are resolved from this specific account, not currentAccount.
        appState.bunkerURI(for: signerPubkey) ?? ""
    }

    var body: some View {
        // Reuse the visual content from the deleted ConnectBunkerTabView —
        // QR code + URI text + Copy / New-secret buttons. Pass `bunkerURI`
        // as the rendered string.
        // ... (copy the visual layout verbatim from ConnectBunkerTabView)
    }
}
```

If `appState.bunkerURI(for:)` doesn't yet exist, add it in `AppState.swift` as a per-signer accessor:

```swift
extension AppState {
    /// Bunker URI for a specific signer (Phase 1 multi-account-aware).
    /// Returns nil if the signer isn't a known account or has no bunker secret.
    func bunkerURI(for signerPubkey: String) -> String? {
        guard accounts.contains(where: { $0.pubkeyHex == signerPubkey }) else {
            return nil
        }
        let secret = SharedStorage.bunkerSecret(for: signerPubkey)
        let relayList = SharedConstants.defaultBunkerRelays.joined(separator: "&relay=")
        return "bunker://\(signerPubkey)?relay=\(relayList)&secret=\(secret)"
    }
}
```

Verify the existing `appState.bunkerURI` computed-property uses similar primitives; the per-signer version is the same expression with `signerPubkey` substituted.

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 5: Commit**

```bash
git add Clave/Views/Connect/ConnectBunkerView.swift \
        Clave/Views/Connect/BunkerURIRender.swift \
        Clave/AppState.swift
git commit -m "$(cat <<'EOF'
feat(connect): ConnectBunkerView with per-signer URI rendering

Phase 1 of multi-account NostrConnect. Bunker child route under the
new Connect tab. Picker fires first (when N >= 2) so the user picks
the account whose bunker URI to share; otherwise auto-skips and
renders directly.

BunkerURIRender extracts the existing ConnectBunkerTabView's visual
content but takes signerPubkey as a parameter — fixes the latent
footgun where today's bunker tab shows currentAccount's URI even
when the user might intend a different account.

AppState.bunkerURI(for:) is the per-signer accessor — same shape
as the current bunkerURI computed property, just parameterized.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 7: Create `ConnectTabView` (the tab root)

**Files:**
- Create: `Clave/Views/Connect/ConnectTabView.swift`

This is the top-level view for the new Connect tab. Hosts `ConnectNostrConnectSurface` as the primary content, navigates to `ConnectBunkerView` via the secondary affordance, and orchestrates the picker → `ApprovalSheet` chain for the NostrConnect flow.

- [ ] **Step 1: Create the file**

Create `Clave/Views/Connect/ConnectTabView.swift`:

```swift
import SwiftUI
import UIKit

/// Root view for the Connect tab — Phase 1 of multi-account NostrConnect.
/// Replaces the previous ConnectSheet (deleted in Task 11) and the
/// "Connect a Client" button on HomeView (removed in Task 10).
///
/// Information architecture: Connect is cross-account. The picker step
/// (ConnectAccountPicker) is where the user explicitly chooses which
/// account they're pairing under. Replaces the implicit identity-bar
/// binding that the old ConnectSheet used.
struct ConnectTabView: View {

    @Environment(AppState.self) private var appState

    @State private var parsedURI: NostrConnectParser.ParsedURI?
    @State private var lastParsedSource: NostrConnectURISource = .paste
    @State private var showPicker = false
    @State private var pickedSignerPubkey: String?
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var pushBunker = false

    var body: some View {
        NavigationStack {
            ConnectNostrConnectSurface(
                parsedURI: parsedURI,
                onParsed: handleParsed,
                onShowBunker: { pushBunker = true }
            )
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $pushBunker) {
                ConnectBunkerView()
            }
            .sheet(isPresented: $showPicker) {
                if let parsed = parsedURI {
                    ConnectAccountPicker(mode: .single, parsedURI: parsed) { pubkeys in
                        pickedSignerPubkey = pubkeys.first
                        showPicker = false
                        presentApproval()
                    }
                }
            }
            .sheet(item: $approvalContext) { ctx in
                ApprovalSheet(parsedURI: ctx.parsedURI,
                              boundAccountPubkey: ctx.signerPubkey) { permissions in
                    submitApproval(uri: ctx.parsedURI,
                                   signerPubkey: ctx.signerPubkey,
                                   permissions: permissions)
                }
            }
            .overlay {
                if isConnecting { connectingOverlay }
            }
            .alert("Connection Failed", isPresented: .init(
                get: { connectionError != nil },
                set: { if !$0 { connectionError = nil } }
            )) {
                Button("OK") { connectionError = nil }
            } message: {
                Text(connectionError ?? "Unknown error")
            }
        }
    }

    // MARK: - State machine

    @State private var approvalContext: ApprovalContext?

    private struct ApprovalContext: Identifiable {
        let id: String   // composite of URI id + signer pubkey
        let parsedURI: NostrConnectParser.ParsedURI
        let signerPubkey: String
    }

    private func handleParsed(_ uri: NostrConnectParser.ParsedURI, source: NostrConnectURISource) {
        parsedURI = uri
        lastParsedSource = source

        // Auto-skip picker when only 1 account exists.
        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            pickedSignerPubkey = only.pubkeyHex
            presentApproval()
        } else {
            showPicker = true
        }
    }

    private func presentApproval() {
        guard let uri = parsedURI, let signer = pickedSignerPubkey else { return }
        approvalContext = ApprovalContext(
            id: uri.id + ":" + signer,
            parsedURI: uri,
            signerPubkey: signer
        )
    }

    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                signerPubkey: String,
                                permissions: ClientPermissions) {
        isConnecting = true
        connectionError = nil
        approvalContext = nil
        parsedURI = nil
        pickedSignerPubkey = nil

        Task { @MainActor in
            // Extend foreground execution so the handshake survives the user
            // swiping to the client app mid-flight (build-62 bg-task pattern).
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "nostrconnect-handshake") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            do {
                let result = try await appState.handleNostrConnect(
                    parsedURI: uri,
                    signerPubkeys: [signerPubkey],
                    permissions: permissions
                )
                isConnecting = false
                if result.isAllFailure {
                    connectionError = result.failed.first?.errorMessage ?? "Unknown error"
                }
                // Success-only and partial cases dismiss naturally for single-mode
                // (partial-failure UX lands in Phase 2 with multi-mode).
            } catch {
                connectionError = error.localizedDescription
                isConnecting = false
            }
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
    }

    // MARK: - Connecting overlay (lifted from the deleted ConnectSheet)

    private var connectingOverlay: some View {
        let subtitle: String = switch lastParsedSource {
        case .paste:
            "Switch back to your client app to finish connecting. Clave keeps running in the background."
        case .qrScan:
            "Stay in Clave for a few seconds"
        }
        return ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                VStack(spacing: 6) {
                    Text("Connecting...")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS. The view isn't wired into MainTabView yet (Task 8); it just compiles.

- [ ] **Step 3: Commit**

```bash
git add Clave/Views/Connect/ConnectTabView.swift
git commit -m "$(cat <<'EOF'
feat(connect): ConnectTabView root view

Phase 1 of multi-account NostrConnect. Top-level view for the new
Connect tab. Hosts ConnectNostrConnectSurface as primary content,
navigates to ConnectBunkerView via the "Or share a code from Clave"
secondary affordance.

State machine for NostrConnect flow: paste/scan → parse → picker
(auto-skipped if N=1) → ApprovalSheet → handshake under
UIBackgroundTask (build-62 pattern preserved). Single-mode only;
multi-mode wiring lands in Phase 2.

Not yet wired into MainTabView — that happens in Task 8.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8: Add Connect as the 4th tab in `MainTabView`

**Files:**
- Modify: `Clave/Views/MainTabView.swift`

- [ ] **Step 1: Add the Connect tab**

In `Clave/Views/MainTabView.swift`, modify the `TabView` body (currently lines 12-27) to add Connect as the second tab (after Home, before Activity):

```swift
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            ConnectTabView()
                .tabItem {
                    Label("Connect", systemImage: "link.circle.fill")
                }

            ActivityView()
                .tabItem {
                    Label("Activity", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
```

Connect goes between Home and Activity because:
- Home is the primary surface (per-account dashboard) — stays first
- Connect is an action surface — second
- Activity is review-oriented (cross-account log) — third
- Settings is configuration — last

- [ ] **Step 2: Build + run in simulator**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 3: Smoke test the tab in simulator**

Manual verification (per project convention — no UI tests):
1. Launch Clave in simulator
2. Verify the bottom tab bar shows: Home | Connect | Activity | Settings
3. Tap Connect → ConnectTabView opens, camera viewfinder + paste field visible
4. Tap "Or share a code from Clave →" affordance → ConnectBunkerView pushes
5. Back to Connect → paste a `nostrconnect://...` URI → ConnectAccountPicker presents (if N≥2 accounts) OR ApprovalSheet presents directly (if N=1)

If any step fails, fix before committing.

- [ ] **Step 4: Commit**

```bash
git add Clave/Views/MainTabView.swift
git commit -m "$(cat <<'EOF'
feat(connect): add Connect as 4th tab in MainTabView

Phase 1 of multi-account NostrConnect. Promotes Connect from a
HomeView-presented sheet to a top-level cross-account tab.

Position: between Home and Activity. Rationale per spec — Home is
per-account dashboard (primary), Connect is action (second),
Activity is review (third), Settings last.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 9: Remove Connect-a-Client button from `HomeView`

**Files:**
- Modify: `Clave/Views/Home/HomeView.swift`

- [ ] **Step 1: Find the Connect button and sheet trigger**

Run:
```bash
cd /Users/danielwyler/clave/Clave && grep -n "showConnectSheet\|ConnectSheet()" Clave/Views/Home/HomeView.swift
```

Verify the matches at lines 7, 165, 168, 283 (per earlier exploration).

- [ ] **Step 2: Remove the button + sheet**

In `Clave/Views/Home/HomeView.swift`:

- Remove the `@State private var showConnectSheet = false` declaration (around line 7)
- Remove the `.sheet(isPresented: $showConnectSheet, ...)` modifier and its closure (around lines 165-170)
- Remove the `showConnectSheet = true` action (around line 283) and the button/CTA that wraps it — replace with text pointing at the Connect tab

For the empty-state CTA (the "Connect a Client" button for users with zero paired clients): replace with a Text label:

```swift
Text("Tap **Connect** in the tab bar to pair your first app.")
    .font(.subheadline)
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .padding()
```

Other places where the button might appear (a toolbar button, a "+" in the navigation bar, etc.) — remove entirely. The Connect tab is now the single entry point.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 4: Smoke test**

Manual verification:
1. Launch Clave
2. Navigate to Home tab — verify no "Connect a Client" button anywhere
3. If user has 0 paired clients, empty-state text points at Connect tab
4. Tap Connect tab — works as in Task 8

- [ ] **Step 5: Commit**

```bash
git add Clave/Views/Home/HomeView.swift
git commit -m "$(cat <<'EOF'
refactor(home): remove Connect-a-Client sheet trigger from HomeView

Phase 1 of multi-account NostrConnect. HomeView no longer presents
ConnectSheet — Connect is now its own top-level tab (Task 8). The
sheet trigger button is removed; the empty-state CTA for users with
zero paired clients is replaced with a Text label pointing at the
Connect tab.

This makes Connect a cross-account action surface (matches Activity
and Settings, which were already cross-account). Per-account
binding for connect-time actions now happens explicitly via
ConnectAccountPicker at the moment of pairing, not implicitly via
the identity-bar selection.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 10: Verify deeplink path still routes through `ConnectAccountPicker`

**Files:**
- Modify: `Clave/ClaveApp.swift` (if needed)
- Modify: any view that presents `DeeplinkAccountPicker` references — should already be `ConnectAccountPicker` after Task 3

- [ ] **Step 1: Audit deeplink routing**

Find all references to the deeplink picker:

```bash
cd /Users/danielwyler/clave/Clave && grep -rn "pendingDeeplinkAccountChoice\|DeeplinkAccountPicker\|ConnectAccountPicker" Clave --include="*.swift"
```

Verify:
1. `AppState+NostrConnect.swift` sets `pendingDeeplinkAccountChoice` on deeplink-with-multiple-accounts (Task 2 left this intact)
2. The view that presents the picker for this state references `ConnectAccountPicker`, not the old `DeeplinkAccountPicker` (Task 3 renamed all references)

- [ ] **Step 2: Smoke test the deeplink path**

Manual verification:
1. In a different app (e.g. Safari), type `nostrconnect://abc?relay=wss://relay.example.com&secret=test&name=TestApp` and tap it
2. Clave opens via Universal Link / scheme
3. If N ≥ 2 accounts, `ConnectAccountPicker` presents
4. User picks an account
5. `ApprovalSheet` presents
6. User taps Approve — handshake runs (may fail due to fake URI, but the flow shape is what matters)

If step 3 doesn't fire, check `AppState.handleDeeplink` and the view subscribing to `pendingDeeplinkAccountChoice`.

- [ ] **Step 3: Commit (if changes were needed)**

If audit + smoke surfaced any drift, commit the fixes. If everything was already consistent from Task 3, skip the commit — this task is purely verification.

### Task 11: Delete old `Connect/` directory

**Files:**
- Delete: `Clave/Views/Home/Connect/ConnectSheet.swift`
- Delete: `Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift`
- Delete: `Clave/Views/Home/Connect/ConnectBunkerTabView.swift`
- Delete: `Clave/Views/Home/Connect/ConnectAccountContextBar.swift` (if exists as separate file)

`DeeplinkAccountPicker.swift` was already deleted in Task 3.

- [ ] **Step 1: Verify nothing still references these files**

```bash
cd /Users/danielwyler/clave/Clave && grep -rn "ConnectSheet\|ConnectNostrconnectTabView\|ConnectBunkerTabView\|ConnectAccountContextBar" Clave ClaveTests --include="*.swift"
```

Expected: zero or only comments mentioning these (in the new files' migration notes). If a Swift file still imports any of these types, fix it before deletion.

- [ ] **Step 2: Check for `ConnectAccountContextBar` usage outside the Connect surface**

The spec notes the bar might be reused. Search broadly:

```bash
grep -rn "ConnectAccountContextBar" /Users/danielwyler/clave/Clave/Clave --include="*.swift"
```

If it's only referenced from the about-to-be-deleted `ConnectSheet.swift`, delete the file too. If it's reused elsewhere, leave the bar file in place but delete just `ConnectSheet.swift`.

- [ ] **Step 3: Delete the files**

```bash
cd /Users/danielwyler/clave/Clave
git rm Clave/Views/Home/Connect/ConnectSheet.swift
git rm Clave/Views/Home/Connect/ConnectNostrconnectTabView.swift
git rm Clave/Views/Home/Connect/ConnectBunkerTabView.swift
# If ConnectAccountContextBar exists as a separate file AND is only used by ConnectSheet:
# git rm Clave/Views/Home/Connect/ConnectAccountContextBar.swift
```

- [ ] **Step 4: Remove the now-empty `Connect/` directory**

```bash
rmdir Clave/Views/Home/Connect 2>/dev/null || echo "Directory not empty — investigate before forcing"
```

If the directory has remaining files (e.g. `ConnectHelpSheet.swift`), move them to `Clave/Views/Connect/` first:

```bash
mv Clave/Views/Home/Connect/*.swift Clave/Views/Connect/ 2>/dev/null
rmdir Clave/Views/Home/Connect
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS. If a file still resolves to the old path, the Xcode project file may need a manual cleanup of the Connect/ group reference.

- [ ] **Step 6: Run full test suite**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -20`

Expected: all 28+ tests PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(connect): delete old ConnectSheet + Connect/ directory

Phase 1 of multi-account NostrConnect. Removes the now-unused
files replaced by the new Clave/Views/Connect/ structure:
- ConnectSheet.swift (replaced by ConnectTabView)
- ConnectNostrconnectTabView.swift (replaced by ConnectNostrConnectSurface)
- ConnectBunkerTabView.swift (replaced by ConnectBunkerView)
- ConnectAccountContextBar references (function moved into the picker step)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 12: Verify all `handleNostrConnect` call sites updated

**Files:**
- Audit only: `Clave/**/*.swift`

- [ ] **Step 1: Find all callers**

```bash
cd /Users/danielwyler/clave/Clave && grep -rn "handleNostrConnect" Clave ClaveTests --include="*.swift"
```

- [ ] **Step 2: Verify each caller uses the new signature**

For every match, confirm it uses:
```swift
appState.handleNostrConnect(parsedURI:, signerPubkeys: [singlePubkey], permissions:)
```

Not:
```swift
appState.handleNostrConnect(parsedURI:, permissions:, boundAccountPubkey:)
```

If any caller still uses the old signature, the build would have failed in earlier tasks — but double-check after the file deletions in Task 11.

- [ ] **Step 3: Confirm build is still clean**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS.

No commit needed — verification only.

### Task 13: Phase 1 full regression smoke test

**Files:** none

- [ ] **Step 1: Run the entire test suite**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -30`

Expected: ALL tests pass. If any test fails that was passing pre-Phase 1, fix the regression before moving on.

- [ ] **Step 2: Real-device smoke test (manual)**

On a real device with a TestFlight build or development build:

1. **Single-account user**: pair Clave with a NostrConnect client (e.g. nostrudel). Verify the flow: open Connect tab → paste/scan URI → picker auto-skips → ApprovalSheet presents → Approve → handshake completes → client pairs successfully.

2. **Multi-account user (2+ accounts)**: pair Clave with one client to Account A:
   - Open Connect tab → paste/scan URI → `ConnectAccountPicker` presents
   - Select Account A → ApprovalSheet presents with `boundAccountPubkey = A`
   - Approve → handshake succeeds → client paired to A
   - Repeat with Account B from a fresh URI → client paired to B
   - Verify both accounts now appear as paired in their respective `ClientDetailView`s

3. **Bunker flow**:
   - Connect tab → tap "Or share a code from Clave →"
   - `ConnectAccountPicker` presents (if N≥2) → pick Account B
   - Bunker URI/QR renders for Account B (not Account A, even if A is sidebar-active)
   - Paste the URI into a client → client pairs successfully to B

4. **Deeplink path** (external `nostrconnect://` link):
   - From Safari, tap a `nostrconnect://...` link
   - Clave opens → `ConnectAccountPicker` presents (if N≥2)
   - Pick an account → ApprovalSheet → Approve → success

5. **HomeView empty state**:
   - On an account with zero paired clients, verify Home shows the "Tap Connect to pair your first app" text — no Connect button

- [ ] **Step 3: If anything fails, fix and re-run**

Document any new bugs as TODOs (or fix them inline). Each fix is a separate commit with the appropriate message.

- [ ] **Step 4: Tag the Phase 1 completion point**

```bash
cd /Users/danielwyler/clave/Clave
git tag spec-multi-account-nostrconnect-phase-1-complete
```

This is a local annotated tag for sequencing purposes — not pushed.

### Task 14: Open Phase 1 PR

**Files:** none (PR creation)

- [ ] **Step 1: Create a Phase 1 implementation branch off main**

The Phase 1 work has been on `spec/multi-account-nostrconnect`. For the actual PR, branch off main:

```bash
cd /Users/danielwyler/clave/Clave
git fetch origin main
git checkout -b feat/connect-tab-restructure origin/main

# Cherry-pick the Phase 1 commits from spec/multi-account-nostrconnect:
# (commits between the spec commit at 23e7473 and the Phase 1 tag)
git cherry-pick 23e7473..spec-multi-account-nostrconnect-phase-1-complete
```

Alternative: squash all Phase 1 commits into one feature commit if the repo prefers that pattern. Check existing PR history to match convention.

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin feat/connect-tab-restructure
gh pr create --title "feat(connect): Phase 1 — Connect tab + picker unification" --body "$(cat <<'EOF'
## Summary

Phase 1 of multi-account NostrConnect ([spec](docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md)).

- Promotes Connect from a HomeView-presented sheet to a top-level cross-account `MainTabView` tab
- Unifies account-binding consent through a single `ConnectAccountPicker` (renamed from `DeeplinkAccountPicker`), used by all 3 entry paths (in-app NostrConnect, in-app bunker, external deeplink)
- Auto-skips the picker when `accounts.count == 1` — single-account users see zero added friction
- Refactors `handleNostrConnect` to an array-shaped signature with `HandshakeResult` return (always 1-element in Phase 1; Phase 2 enables N > 1)
- UX shape γ: NostrConnect (scan/paste) is the primary surface, bunker is a secondary affordance

No protocol changes. No backwards compat concerns. No Tableau dependency.

## Test plan
- [ ] All existing tests pass (`xcodebuild ... test`)
- [ ] Single-account user: pair via Connect tab — picker auto-skips, handshake succeeds
- [ ] Multi-account user: pair via Connect tab — picker presents, handshake succeeds for chosen account
- [ ] Bunker flow: picker fires before URI render, URI is for the chosen (non-current) account
- [ ] Deeplink: external `nostrconnect://` routes through `ConnectAccountPicker` exactly as before
- [ ] HomeView no longer presents `ConnectSheet`; empty-state text points at Connect tab

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Stop here for Phase 1**

After PR opens, Phase 1 implementation is complete. **Do NOT start Phase 2 until Phase 1 ships** — Phase 2's correctness depends on the refactored Phase 1 foundations being on `main`.

---

## Phase 2 — Multi-account NostrConnect protocol opt-in

**Goal of this phase:** layer the `accounts=multi` protocol opt-in on Phase 1's foundation. After Phase 2, a NostrConnect client that sets `accounts=multi` in its URI can pair with N of the user's accounts in one handshake. All backwards-compatibility properties preserved.

**Prerequisite:** Phase 1 has shipped to main. Branch off main for Phase 2 work, NOT off Phase 1's feature branch.

**Estimated total tasks:** 12.

**Phase 2 acceptance criteria** (from spec, lines 416-422):
- URI parser sets `isMultiAccount = true` for `accounts=multi` URIs (unit test)
- Picker `.multi` mode renders correctly with cap-disabled rows (unit test + smoke)
- `handleNostrConnect` N-up loop returns correct `HandshakeResult` for all-success / partial / all-failure (unit tests)
- Backwards-compat: old single-account URI through new Clave behaves as today (smoke test)
- End-to-end with Tableau: paste multi URI in Clave, select 2+ accounts, observe Tableau receive N acks within listening window (integration smoke; depends on Tableau-side plan in `/Users/danielwyler/tableau/...`)
- Manual probe of relay tolerance for rapid N kind:24133 events on `#p:client_pk`

### Task 15: Add `isMultiAccount` to `ParsedURI`

**Files:**
- Modify: `Clave/Shared/NostrConnectParser.swift`
- Test: `ClaveTests/NostrConnectParserMultiAccountTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/NostrConnectParserMultiAccountTests.swift`:

```swift
import XCTest
@testable import Clave

final class NostrConnectParserMultiAccountTests: XCTestCase {

    func testAccountsMultiFlagDetected() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=s&accounts=multi"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertTrue(parsed.isMultiAccount)
    }

    func testAccountsMultiFlagAbsent() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=s"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertFalse(parsed.isMultiAccount)
    }

    func testAccountsParamWithDifferentValueIgnored() throws {
        // Only `accounts=multi` enables the flag; other values are ignored
        // (forward-compat with future schemes like `accounts=2` if that's
        // ever added).
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=s&accounts=single"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertFalse(parsed.isMultiAccount)
    }

    func testAccountsMultiPreservesOtherFields() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.com&secret=s&accounts=multi&name=Tableau&perms=sign_event%3A1"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertTrue(parsed.isMultiAccount)
        XCTAssertEqual(parsed.name, "Tableau")
        XCTAssertEqual(parsed.requestedPerms, ["sign_event:1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/NostrConnectParserMultiAccountTests 2>&1 | tail -10`

Expected: build FAILS with `value of type 'NostrConnectParser.ParsedURI' has no member 'isMultiAccount'`.

- [ ] **Step 3: Add the field + parsing**

In `Clave/Shared/NostrConnectParser.swift`:

Add the field to `ParsedURI`:
```swift
    struct ParsedURI: Identifiable {
        var id: String { clientPubkey + secret }
        let clientPubkey: String
        let relays: [String]
        let secret: String
        let requestedPerms: [String]
        let name: String?
        let url: String?
        let imageURL: String?
        let suggestedTrustLevel: TrustLevel
        let isMultiAccount: Bool   // NEW: true iff `accounts=multi` was present
    }
```

Add the parse step in `parse(_:)` (after the `imageURL` parse, before the trust-level computation):
```swift
        let accountsParam = queryItems.first(where: { $0.name == "accounts" })?.value
        let isMultiAccount = accountsParam == "multi"
```

Add to the `ParsedURI(...)` constructor:
```swift
        return ParsedURI(
            clientPubkey: clientPubkey,
            relays: relays,
            secret: secret,
            requestedPerms: requestedPerms,
            name: name,
            url: url,
            imageURL: imageURL,
            suggestedTrustLevel: suggestedTrustLevel,
            isMultiAccount: isMultiAccount
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:ClaveTests/NostrConnectParserMultiAccountTests 2>&1 | tail -10`

Expected: 4 tests, all PASS.

Also re-run the original `NostrConnectParserTests` to verify nothing broke:

`xcodebuild ... test -only-testing:ClaveTests/NostrConnectParserTests`

Expected: 9 tests, all PASS (no regressions).

- [ ] **Step 5: Commit**

```bash
git add Clave/Shared/NostrConnectParser.swift ClaveTests/NostrConnectParserMultiAccountTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): parse accounts=multi URI flag in NostrConnectParser

Phase 2 of multi-account NostrConnect. Adds isMultiAccount: Bool
to ParsedURI; parser sets it iff the URI carries accounts=multi.
Other accounts= values (e.g. accounts=single) parse to false —
forward-compat with future schemes.

All existing fields preserved; existing test suite unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 16: Add `PairAccountCapInfo` + cap pre-flight helper

**Files:**
- Create: `Clave/Models/PairAccountCapInfo.swift`
- Modify: `Clave/Shared/SharedStorage.swift`
- Test: `ClaveTests/PairAccountCapInfoTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/PairAccountCapInfoTests.swift`:

```swift
import XCTest
@testable import Clave

final class PairAccountCapInfoTests: XCTestCase {

    func testBelowCap() {
        let info = PairAccountCapInfo(signerPubkey: "pk1", currentPairCount: 2)
        XCTAssertFalse(info.isAtCap)
        XCTAssertEqual(info.remaining, 3)
    }

    func testAtCap() {
        let info = PairAccountCapInfo(signerPubkey: "pk1", currentPairCount: 5)
        XCTAssertTrue(info.isAtCap)
        XCTAssertEqual(info.remaining, 0)
    }

    func testAboveCap() {
        // Defensive: if storage somehow contains 6+ pairs (race, bug, manual
        // edit), treat as capped — never negative remaining.
        let info = PairAccountCapInfo(signerPubkey: "pk1", currentPairCount: 7)
        XCTAssertTrue(info.isAtCap)
        XCTAssertEqual(info.remaining, 0)
    }

    func testCapConstant() {
        // Cap is the single source of truth — matches the proxy's pair-client
        // enforcement (5 pairs/signer per the Phase 1 multi-account sprint).
        XCTAssertEqual(PairAccountCapInfo.cap, 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:ClaveTests/PairAccountCapInfoTests`

Expected: build FAILS — `PairAccountCapInfo` not in scope.

- [ ] **Step 3: Create the type**

Create `Clave/Models/PairAccountCapInfo.swift`:

```swift
import Foundation

/// Cap pre-flight info for one account in the multi-select picker. Computed
/// at picker render time so capped accounts can be visually disabled with a
/// "5/5 clients" badge before the user commits to a multi-pair operation.
///
/// The cap (5 distinct paired clients per signer) is enforced server-side
/// by the proxy's `pair-client` endpoint. This struct is a client-side
/// view of the same constraint, used for UX-side surfacing only — the proxy
/// is the source of truth.
struct PairAccountCapInfo: Equatable {

    /// Maximum distinct paired clients per signer. Mirrors the proxy's
    /// `pair-client` enforcement.
    static let cap = 5

    let signerPubkey: String
    let currentPairCount: Int

    var isAtCap: Bool { currentPairCount >= Self.cap }
    var remaining: Int { max(0, Self.cap - currentPairCount) }
}
```

- [ ] **Step 4: Add the SharedStorage helper**

In `Clave/Shared/SharedStorage.swift`, add:

```swift
    /// Count of distinct paired clients for a given signer. Used by the
    /// multi-mode picker to pre-flight the per-signer cap (5).
    static func pairCountForSigner(_ signerPubkey: String) -> Int {
        getConnectedClients(for: signerPubkey).count
    }
```

(Verify the existing method signature `getConnectedClients(for:)` exists — it should, per the multi-account sprint notes.)

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild ... test -only-testing:ClaveTests/PairAccountCapInfoTests`

Expected: 4 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
git add Clave/Models/PairAccountCapInfo.swift \
        Clave/Shared/SharedStorage.swift \
        ClaveTests/PairAccountCapInfoTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): PairAccountCapInfo + pairCountForSigner helper

Phase 2 of multi-account NostrConnect. Cap pre-flight value type
for picker rendering: tracks (signer, currentPairCount), derives
isAtCap + remaining.

SharedStorage.pairCountForSigner(_:) is the read-side helper —
counts entries from the existing getConnectedClients(for:) accessor
(unchanged storage shape, just a new view).

Cap constant (5) matches the proxy's pair-client enforcement. The
proxy is the source of truth; this is a client-side UX surface
for the same constraint.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 17: Implement `.multi` mode in `ConnectAccountPicker`

**Files:**
- Modify: `Clave/Views/Connect/ConnectAccountPicker.swift`
- Test: `ClaveTests/ConnectAccountPickerMultiModeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/ConnectAccountPickerMultiModeTests.swift`:

```swift
import XCTest
@testable import Clave

/// UI rendering tests for ConnectAccountPicker .multi mode. Verifies the
/// default-selection rules and cap-disabled-row behavior via the picker's
/// pure-logic helpers (no SwiftUI render in unit tests — that's a smoke
/// concern).
final class ConnectAccountPickerMultiModeTests: XCTestCase {

    func testDefaultSelection_5OrFewer_AllChecked() {
        let pubkeys = ["pk1", "pk2", "pk3", "pk4", "pk5"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: Set()
        )
        XCTAssertEqual(selected, Set(pubkeys))
    }

    func testDefaultSelection_MoreThan5_NoneChecked() {
        let pubkeys = ["pk1", "pk2", "pk3", "pk4", "pk5", "pk6"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: Set()
        )
        XCTAssertEqual(selected, Set())
    }

    func testDefaultSelection_5OrFewer_CappedExcluded() {
        // When ≤5 accounts AND some are capped, only the non-capped ones
        // are default-checked.
        let pubkeys = ["pk1", "pk2", "pk3"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: ["pk2"]
        )
        XCTAssertEqual(selected, Set(["pk1", "pk3"]))
    }

    func testCanProceed_RequiresAtLeastOneSelected() {
        XCTAssertFalse(ConnectAccountPicker.canProceed(selectedCount: 0))
        XCTAssertTrue(ConnectAccountPicker.canProceed(selectedCount: 1))
        XCTAssertTrue(ConnectAccountPicker.canProceed(selectedCount: 5))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:ClaveTests/ConnectAccountPickerMultiModeTests`

Expected: build FAILS — `defaultSelection` / `canProceed` not found.

- [ ] **Step 3: Add the helper functions**

In `Clave/Views/Connect/ConnectAccountPicker.swift`, add inside the struct:

```swift
    /// Default selection set for `.multi` mode. Rules:
    ///   - if total accounts ≤ 5: all non-capped accounts are pre-checked
    ///   - if total accounts > 5: none are pre-checked (deliberate selection
    ///     on large account sets)
    /// Capped accounts are NEVER pre-checked regardless of count — the user
    /// would just have to uncheck them.
    static func defaultSelection(
        for pubkeys: [String],
        cappedSigners: Set<String>
    ) -> Set<String> {
        if pubkeys.count <= 5 {
            return Set(pubkeys).subtracting(cappedSigners)
        } else {
            return Set()
        }
    }

    /// Whether the Continue button is enabled — at least 1 account must be
    /// selected. Used by the multi-mode rendering.
    static func canProceed(selectedCount: Int) -> Bool {
        selectedCount >= 1
    }
```

- [ ] **Step 4: Implement the multi-mode SwiftUI rendering**

Modify the `body` and `accountRow(for:)` methods in `ConnectAccountPicker.swift` to support `.multi` mode. Replace the body:

```swift
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                    .padding(.horizontal)
                    .padding(.top, 8)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.accounts) { account in
                            accountRow(for: account)
                        }
                    }
                    .padding(.horizontal)
                }
                if case .multi = mode {
                    continueButton
                        .padding()
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .snapshotProtected()
        .onAppear(perform: setupMultiModeDefaults)
    }

    // MARK: - Multi-mode state

    @State private var multiSelected: Set<String> = []
    @State private var cappedSigners: Set<String> = []

    private func setupMultiModeDefaults() {
        guard case .multi = mode else { return }
        // Compute capped signers
        cappedSigners = Set(
            appState.accounts
                .map(\.pubkeyHex)
                .filter { PairAccountCapInfo(
                    signerPubkey: $0,
                    currentPairCount: SharedStorage.pairCountForSigner($0)
                ).isAtCap }
        )
        // Apply default selection
        multiSelected = Self.defaultSelection(
            for: appState.accounts.map(\.pubkeyHex),
            cappedSigners: cappedSigners
        )
    }

    private var continueButton: some View {
        Button {
            onPick(Array(multiSelected))
            dismiss()
        } label: {
            Text("Continue with \(multiSelected.count) account\(multiSelected.count == 1 ? "" : "s")")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!Self.canProceed(selectedCount: multiSelected.count))
    }
```

Modify `accountRow(for:)` to render differently in multi mode:

```swift
    private func accountRow(for account: Account) -> some View {
        let theme = AccountTheme.forAccount(pubkeyHex: account.pubkeyHex)
        let isCapped = cappedSigners.contains(account.pubkeyHex)
        let isChecked = multiSelected.contains(account.pubkeyHex)

        return Button {
            switch mode {
            case .single:
                onPick([account.pubkeyHex])
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dismiss()
            case .multi:
                guard !isCapped else { return }
                if isChecked {
                    multiSelected.remove(account.pubkeyHex)
                } else {
                    multiSelected.insert(account.pubkeyHex)
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } label: {
            HStack(spacing: 14) {
                if case .multi = mode {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isCapped ? .secondary : theme.accent)
                }
                AvatarView(pubkeyHex: account.pubkeyHex,
                           name: account.displayLabel,
                           size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(account.displayLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isCapped ? .secondary : .primary)
                    Text(String(account.pubkeyHex.prefix(12)) + "…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCapped {
                    Text("\(PairAccountCapInfo.cap)/\(PairAccountCapInfo.cap) clients")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .opacity(isCapped ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isCapped)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild ... test -only-testing:ClaveTests/ConnectAccountPickerMultiModeTests`

Expected: 4 tests, all PASS.

- [ ] **Step 6: Build to verify**

Run: `xcodebuild -workspace Clave.xcworkspace -scheme Clave -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 7: Commit**

```bash
git add Clave/Views/Connect/ConnectAccountPicker.swift ClaveTests/ConnectAccountPickerMultiModeTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): implement ConnectAccountPicker .multi mode

Phase 2 of multi-account NostrConnect. Adds:
- Checkbox-style multi-select rendering
- Default-selection rules: ≤5 accounts → all (non-capped) checked,
  >5 → none checked
- Cap pre-flight: rows where signer is at the 5-pair cap render
  disabled with a "5/5 clients" badge inline
- "Continue with N accounts" button at the sheet's bottom; disabled
  when nothing selected

Picker stays a sheet step BEFORE ApprovalSheet — the two-step flow
("which accounts" → "what permissions + approve") is preserved
across single and multi modes per Decision 1.

Capped signers are excluded from default-checked sets so the user
isn't asked to uncheck unreachable rows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 18: Extend `LightSigner` to emit enriched JSON `result` for multi-account acks

**Files:**
- Modify: `Clave/Shared/LightSigner.swift`
- Test: `ClaveTests/LightSignerMultiAccountResultTests.swift`

This task changes the connect-ack body for multi-account flow only. Single-account flow keeps emitting the bare `<echoed_secret>` string.

- [ ] **Step 1: Read `LightSigner.swift` to find the current ack-build location**

Per the spec, `LightSigner.swift:564-568` builds the secret-echo response. Read those lines:

```bash
cd /Users/danielwyler/clave/Clave && sed -n '560,580p' Shared/LightSigner.swift
```

Identify the current response body construction — it builds `{"id":..., "result":"<secret>"}`.

- [ ] **Step 2: Write the failing test**

Create `ClaveTests/LightSignerMultiAccountResultTests.swift`:

```swift
import XCTest
@testable import Clave

final class LightSignerMultiAccountResultTests: XCTestCase {

    func testSingleAccountResultIsBareSecret() {
        // Single-account flow (isMultiAccount: false) emits the existing
        // string-secret format — preserves backwards compat for all
        // existing clients.
        let result = LightSigner.connectAckResult(
            isMultiAccount: false,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: "https://example.com/p.png"
        )
        XCTAssertEqual(result, "abc123")
    }

    func testMultiAccountResultIsJSON() throws {
        // Multi-account flow emits a JSON object so the client can render
        // account labels without a follow-up kind:0 fetch.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: "https://example.com/p.png"
        )
        guard let data = result.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            XCTFail("Multi-account result is not valid JSON: \(result)")
            return
        }
        XCTAssertEqual(json["echoed_secret"], "abc123")
        XCTAssertEqual(json["name"], "alice")
        XCTAssertEqual(json["picture"], "https://example.com/p.png")
    }

    func testMultiAccountResultOmitsNilFields() throws {
        // Account without a cached profile — name + picture absent — but
        // echoed_secret always present.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: nil,
            accountPicture: nil
        )
        guard let data = result.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            XCTFail("Multi-account result is not valid JSON: \(result)")
            return
        }
        XCTAssertEqual(json["echoed_secret"], "abc123")
        XCTAssertNil(json["name"])
        XCTAssertNil(json["picture"])
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:ClaveTests/LightSignerMultiAccountResultTests`

Expected: build FAILS — `connectAckResult` not found.

- [ ] **Step 4: Add the builder to `LightSigner`**

In `Clave/Shared/LightSigner.swift`, add as a static method:

```swift
    /// Build the `result` field for a NIP-46 `connect` ack.
    ///
    /// Single-account (`isMultiAccount: false`): bare echoed-secret string,
    /// matching today's behavior. Backwards-compatible with all existing
    /// clients including those that string-compare `result == secret`.
    ///
    /// Multi-account (`isMultiAccount: true`): JSON object with the same
    /// echoed_secret plus optional name + picture metadata for the signer
    /// account. Lets clients (e.g. Tableau) populate account-switcher labels
    /// without a follow-up kind:0 fetch.
    static func connectAckResult(
        isMultiAccount: Bool,
        echoedSecret: String,
        accountName: String?,
        accountPicture: String?
    ) -> String {
        guard isMultiAccount else {
            return echoedSecret
        }
        var fields: [String: String] = ["echoed_secret": echoedSecret]
        if let name = accountName, !name.isEmpty {
            fields["name"] = name
        }
        if let picture = accountPicture, !picture.isEmpty {
            fields["picture"] = picture
        }
        // Sorted keys for deterministic output (eases tests + log diffing)
        guard let data = try? JSONSerialization.data(
                withJSONObject: fields,
                options: [.sortedKeys]
              ),
              let str = String(data: data, encoding: .utf8) else {
            // Fallback: if JSON serialization fails (which shouldn't happen
            // for plain string fields), degrade to bare secret rather than
            // breaking the handshake.
            return echoedSecret
        }
        return str
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild ... test -only-testing:ClaveTests/LightSignerMultiAccountResultTests`

Expected: 3 tests, all PASS.

- [ ] **Step 6: Wire the builder into the existing ack-build site**

Locate `LightSigner.swift:~564-568` (the existing connect-ack construction). Replace the hard-coded `parsedURI.secret` with the builder call. The exact integration depends on where the ack is built — `AppState+NostrConnect.swift:97` is one site:

```swift
            // Before:
            // let responseDict: [String: Any] = ["id": responseId, "result": parsedURI.secret]
            // After:
            let resultField = LightSigner.connectAckResult(
                isMultiAccount: parsedURI.isMultiAccount,
                echoedSecret: parsedURI.secret,
                accountName: currentAccountProfile(for: signerPubkey)?.displayName,
                accountPicture: currentAccountProfile(for: signerPubkey)?.picture
            )
            let responseDict: [String: Any] = ["id": responseId, "result": resultField]
```

Add the `currentAccountProfile(for:)` helper if it doesn't exist — it should resolve from `appState.accounts.first(where: { $0.pubkeyHex == signerPubkey })?.profile`.

- [ ] **Step 7: Build to verify**

Run: `xcodebuild build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 8: Commit**

```bash
git add Clave/Shared/LightSigner.swift \
        Clave/AppState+NostrConnect.swift \
        ClaveTests/LightSignerMultiAccountResultTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): enriched JSON connect-ack result for multi-account

Phase 2 of multi-account NostrConnect. Adds
LightSigner.connectAckResult(isMultiAccount:, echoedSecret:,
accountName:, accountPicture:) helper:

  - single-account (isMultiAccount false): bare echoed-secret string,
    matches today's behavior, backwards-compatible with every existing
    client including ones that string-compare result == secret
  - multi-account (isMultiAccount true): JSON {echoed_secret, name,
    picture} so Tableau-like clients can render account labels
    without a follow-up kind:0 fetch

Single-account flow is unchanged; multi-account flow only triggered
when the URI carries accounts=multi (Task 15's parser flag).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 19: N-up handshake loop in `handleNostrConnect`

**Files:**
- Modify: `Clave/AppState+NostrConnect.swift`
- Test: `ClaveTests/AppStateMultiAccountHandshakeTests.swift`

The Phase 1 refactor already moved iteration logic into `handleNostrConnect`. Phase 2 verifies the N>1 path works correctly — the function body is largely unchanged, but the cap pre-flight is integrated and per-iteration progress callbacks are added.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/AppStateMultiAccountHandshakeTests.swift`:

```swift
import XCTest
@testable import Clave

/// N-up handshake semantics. The actual handshake is impractical to unit
/// test (live relays); these tests verify the loop-coordination layer:
/// HandshakeResult accumulation, partial-failure handling, capped-signer
/// pre-flight.
final class AppStateMultiAccountHandshakeTests: XCTestCase {

    func testEmptyArrayThrowsAtBoundary() async throws {
        let appState = await AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://abc?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "abc",
            signerPubkeyHex: "",
            permissions: [],
            name: nil,
            addedAt: Date().timeIntervalSince1970
        )
        do {
            _ = try await appState.handleNostrConnect(
                parsedURI: dummyURI,
                signerPubkeys: [],
                permissions: perms
            )
            XCTFail("Expected throw on empty signerPubkeys")
        } catch ClaveError.noSignerKey {
            // expected
        }
    }

    func testHandshakeResultAccumulatesPerIteration() async throws {
        // Verifies the loop populates HandshakeResult correctly for an
        // all-failure case (no nsecs in keychain → every iteration throws).
        let appState = await AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://abc?relay=wss%3A%2F%2Frelay.invalid&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "abc",
            signerPubkeyHex: "",
            permissions: [],
            name: nil,
            addedAt: Date().timeIntervalSince1970
        )
        let result = try await appState.handleNostrConnect(
            parsedURI: dummyURI,
            signerPubkeys: ["nonexistent-pk-1", "nonexistent-pk-2"],
            permissions: perms
        )
        XCTAssertEqual(result.succeeded.count, 0)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(result.failed.map(\.signerPubkey), ["nonexistent-pk-1", "nonexistent-pk-2"])
        XCTAssertTrue(result.isAllFailure)
    }
}
```

- [ ] **Step 2: Run test to verify expected behavior**

Run: `xcodebuild ... test -only-testing:ClaveTests/AppStateMultiAccountHandshakeTests`

Expected: tests PASS (the Phase 1 implementation should already handle the N=2 case correctly — Phase 2's primary change is wiring the loop semantics into the UI, not changing the loop body).

If tests fail, the issue is in the Phase 1 `runSingleConnect` error propagation — the throw from `loadNsec` must reach the outer loop's `catch` cleanly.

- [ ] **Step 3: Commit**

```bash
git add ClaveTests/AppStateMultiAccountHandshakeTests.swift
git commit -m "$(cat <<'EOF'
test(connect): N-up handshake loop semantics

Phase 2 of multi-account NostrConnect. Verifies that the array-shape
handleNostrConnect signature from Phase 1 correctly accumulates
per-iteration results into HandshakeResult.succeeded and
HandshakeResult.failed.

Tests the N=0 boundary (throws ClaveError.noSignerKey) and the
N=2 all-failure case (both signers absent from keychain → both
land in HandshakeResult.failed with correct signerPubkey
attribution).

Live-relay handshake assertions remain in the manual smoke test
(per Task 26).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 20: Extend `ApprovalSheet` for multi-mode

**Files:**
- Modify: `Clave/Views/Home/ApprovalSheet.swift`

Currently `ApprovalSheet` takes `boundAccountPubkey: String` (one). Multi-mode needs `boundAccountPubkeys: [String]` (N) plus rendering changes for the header + selected-account inline list.

- [ ] **Step 1: Read the current `ApprovalSheet`**

Run `cat /Users/danielwyler/clave/Clave/Clave/Views/Home/ApprovalSheet.swift | head -80` to understand its current shape.

- [ ] **Step 2: Migrate `boundAccountPubkey` → `boundAccountPubkeys`**

In `Clave/Views/Home/ApprovalSheet.swift`:

```swift
struct ApprovalSheet: View {
    let parsedURI: NostrConnectParser.ParsedURI
    let boundAccountPubkeys: [String]   // was: String
    let onApprove: (ClientPermissions) -> Void

    // ... existing state ...

    private var isMulti: Bool { boundAccountPubkeys.count > 1 }

    var body: some View {
        // ... existing layout, plus:
        if isMulti {
            multiHeader
            selectedAccountsInlineList
        } else {
            singleHeader
        }

        // ... existing permissions block (unchanged) ...

        approveButton
    }

    private var singleHeader: some View {
        Text("Connect \(clientName)?")
            .font(.title2.weight(.semibold))
    }

    private var multiHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(clientName) is requesting to sign for \(boundAccountPubkeys.count) accounts")
                .font(.title3.weight(.semibold))
            Text("Approve to pair \(clientName) with each of the accounts below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedAccountsInlineList: some View {
        // Compact horizontal scroll of avatars + labels for the N selected
        // accounts. Tapping a row could expand to show pubkey (out of scope
        // for v1 — just render the list inline).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(boundAccountPubkeys, id: \.self) { pubkey in
                    accountChip(pubkey: pubkey)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func accountChip(pubkey: String) -> some View {
        // Resolve account from appState for label + avatar
        // ... visual treatment ...
    }

    private var approveButton: some View {
        Button {
            let perms = composedPermissions()
            onApprove(perms)
        } label: {
            Text(isMulti
                 ? "Approve \(boundAccountPubkeys.count) accounts"
                 : "Approve")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }
}
```

The exact existing structure of `ApprovalSheet` may differ; preserve all existing behavior (permission composition, trust-level UI, etc.) — only ADD the multi-mode branches.

- [ ] **Step 3: Update all call sites**

```bash
cd /Users/danielwyler/clave/Clave && grep -rn "ApprovalSheet(" Clave --include="*.swift"
```

For each call site:
- Old: `ApprovalSheet(parsedURI: x, boundAccountPubkey: y) { ... }`
- New: `ApprovalSheet(parsedURI: x, boundAccountPubkeys: [y]) { ... }` (single-mode callers)
- Multi-mode callers (new in Phase 2): `ApprovalSheet(parsedURI: x, boundAccountPubkeys: yArray) { ... }`

- [ ] **Step 4: Build to verify**

Run: `xcodebuild build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 5: Commit**

```bash
git add Clave/Views/Home/ApprovalSheet.swift Clave/Views/Connect/ConnectTabView.swift
# Plus any other call-site files
git commit -m "$(cat <<'EOF'
feat(connect): ApprovalSheet multi-mode rendering

Phase 2 of multi-account NostrConnect. ApprovalSheet now takes
boundAccountPubkeys: [String] (was boundAccountPubkey: String).
When N == 1: existing single-mode header + Approve button (visual
change minimal). When N >= 2: multi-mode header ("X is requesting
to sign for N accounts"), inline scroll of selected-account chips,
and "Approve N accounts" button.

Permission composition unchanged — one shared permissions block
applies to all N accounts in v1. Per-account customization is
post-pair via ClientDetailView per spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 21: Wire multi-mode end-to-end through `ConnectTabView`

**Files:**
- Modify: `Clave/Views/Connect/ConnectTabView.swift`

- [ ] **Step 1: Update the handleParsed branch for multi**

In `ConnectTabView.swift`, modify `handleParsed`:

```swift
    private func handleParsed(_ uri: NostrConnectParser.ParsedURI, source: NostrConnectURISource) {
        parsedURI = uri
        lastParsedSource = source

        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            // Auto-skip — same as Phase 1
            pickedSignerPubkeys = [only.pubkeyHex]
            presentApproval()
        } else if uri.isMultiAccount {
            // Multi mode picker
            showMultiPicker = true
        } else {
            // Single mode picker (Phase 1 path)
            showPicker = true
        }
    }
```

Rename `pickedSignerPubkey: String?` → `pickedSignerPubkeys: [String]`.

Add `@State private var showMultiPicker = false` next to the existing `showPicker`.

Add the multi-picker sheet:

```swift
            .sheet(isPresented: $showMultiPicker) {
                if let parsed = parsedURI {
                    ConnectAccountPicker(mode: .multi, parsedURI: parsed) { pubkeys in
                        pickedSignerPubkeys = pubkeys
                        showMultiPicker = false
                        if !pubkeys.isEmpty {
                            presentApproval()
                        }
                    }
                }
            }
```

Update `presentApproval` to use the array:

```swift
    private func presentApproval() {
        guard let uri = parsedURI, !pickedSignerPubkeys.isEmpty else { return }
        approvalContext = ApprovalContext(
            id: uri.id + ":" + pickedSignerPubkeys.joined(separator: ","),
            parsedURI: uri,
            signerPubkeys: pickedSignerPubkeys
        )
    }

    private struct ApprovalContext: Identifiable {
        let id: String
        let parsedURI: NostrConnectParser.ParsedURI
        let signerPubkeys: [String]   // was: signerPubkey: String
    }
```

Update `submitApproval` to use the array (it already passes to `handleNostrConnect` which is array-shaped from Phase 1):

```swift
    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                signerPubkeys: [String],
                                permissions: ClientPermissions) {
        isConnecting = true
        // ... existing body ...
        let result = try await appState.handleNostrConnect(
            parsedURI: uri,
            signerPubkeys: signerPubkeys,   // pass array directly
            permissions: permissions
        )
        // ... existing result handling ...
    }
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add Clave/Views/Connect/ConnectTabView.swift
git commit -m "$(cat <<'EOF'
feat(connect): wire multi-mode through ConnectTabView state machine

Phase 2 of multi-account NostrConnect. ConnectTabView routing now
branches on parsedURI.isMultiAccount: multi flag → multi-mode picker
(.multi case) → array of selected pubkeys → ApprovalSheet in
multi-mode → handleNostrConnect with N-pubkey array.

Phase 1's single-mode path is preserved exactly (no flag → single
picker → 1-element array). The flag-based branch is the only added
control flow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 22: Progress UI during the handshake loop

**Files:**
- Modify: `Clave/Views/Home/ApprovalSheet.swift`
- Modify: `Clave/AppState+NostrConnect.swift` (per-iteration progress callback)

The spec calls for "Pairing N of M…" text + active-row highlight + non-dismissable-while-running sheet.

- [ ] **Step 1: Add per-iteration progress callback to `handleNostrConnect`**

Modify `Clave/AppState+NostrConnect.swift`:

```swift
    @discardableResult
    func handleNostrConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        signerPubkeys: [String],
        permissions: ClientPermissions,
        progress: ((_ currentIndex: Int, _ total: Int, _ currentSigner: String) -> Void)? = nil
    ) async throws -> HandshakeResult {
        guard !signerPubkeys.isEmpty else {
            throw ClaveError.noSignerKey
        }

        var succeeded: [String] = []
        var failed: [HandshakeResult.FailedSigner] = []

        for (index, signerPubkey) in signerPubkeys.enumerated() {
            progress?(index, signerPubkeys.count, signerPubkey)
            do {
                try await runSingleConnect(
                    parsedURI: parsedURI,
                    signerPubkey: signerPubkey,
                    permissions: permissions
                )
                succeeded.append(signerPubkey)
            } catch {
                failed.append(HandshakeResult.FailedSigner(
                    signerPubkey: signerPubkey,
                    errorMessage: error.localizedDescription
                ))
            }
        }

        return HandshakeResult(succeeded: succeeded, failed: failed)
    }
```

- [ ] **Step 2: Add progress state to `ApprovalSheet`**

Add `@State` for tracking progress:
```swift
    @State private var progressIndex: Int = 0
    @State private var progressTotal: Int = 0
    @State private var currentlyPairing: String? = nil
    @State private var succeededSoFar: Set<String> = []
```

Add progress rendering during the loop (when `isConnecting`):

```swift
    private var progressOverlay: some View {
        VStack(spacing: 16) {
            ForEach(boundAccountPubkeys, id: \.self) { pubkey in
                progressRow(for: pubkey)
            }
            Text("Pairing \(progressIndex + 1) of \(progressTotal)…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func progressRow(for pubkey: String) -> some View {
        let isCurrent = currentlyPairing == pubkey
        let isDone = succeededSoFar.contains(pubkey)
        let isQueued = !isCurrent && !isDone

        return HStack {
            if isDone {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if isCurrent {
                ProgressView()
            } else {
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            }
            // account avatar + label
            Text(accountLabel(for: pubkey))
                .font(.subheadline)
        }
        .opacity(isQueued ? 0.5 : 1.0)
    }
```

Set the progress callback when invoking `handleNostrConnect`:

```swift
    private func submitApproval(...) {
        // ...
        Task {
            let result = try await appState.handleNostrConnect(
                parsedURI: uri,
                signerPubkeys: signerPubkeys,
                permissions: permissions,
                progress: { idx, total, signer in
                    await MainActor.run {
                        progressIndex = idx
                        progressTotal = total
                        currentlyPairing = signer
                        // Move previous-current to succeeded as we move on
                        if idx > 0 {
                            succeededSoFar.insert(signerPubkeys[idx - 1])
                        }
                    }
                }
            )
            // ...
        }
    }
```

Disable sheet dismissal during the loop:

```swift
    .interactiveDismissDisabled(isConnecting)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 4: Smoke test in simulator**

Manually: paste a multi-account URI in a test build with 2+ accounts → observe "Pairing 1 of 2…", "Pairing 2 of 2…" advance with rows transitioning queued → current → succeeded.

- [ ] **Step 5: Commit**

```bash
git add Clave/Views/Home/ApprovalSheet.swift Clave/AppState+NostrConnect.swift
git commit -m "$(cat <<'EOF'
feat(connect): per-iteration progress UI for multi-pair loop

Phase 2 of multi-account NostrConnect. ApprovalSheet renders a
per-account progress UI during handleNostrConnect's sequential
loop:

  - "Pairing N of M..." live count
  - Per-row status: succeeded (checkmark), current (spinner),
    queued (dotted circle, dimmed)
  - Sheet dismissal disabled while loop runs
    (interactiveDismissDisabled)

handleNostrConnect gains an optional progress callback parameter
that fires before each iteration with (currentIndex, total, signer).
Existing single-mode callers don't pass it (callback is optional);
multi-mode callers pass it from ApprovalSheet to drive the UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 23: Partial-failure result UI

**Files:**
- Modify: `Clave/Views/Home/ApprovalSheet.swift`

After the loop completes, render the result based on `HandshakeResult.isAllSuccess / isPartialFailure / isAllFailure`.

- [ ] **Step 1: Add result state**

In `ApprovalSheet.swift`:

```swift
    @State private var handshakeResult: HandshakeResult? = nil

    private var resultView: some View {
        VStack(spacing: 16) {
            if let result = handshakeResult {
                if result.isAllSuccess {
                    successResultView(result)
                } else if result.isPartialFailure {
                    partialFailureResultView(result)
                } else {
                    // all-failure handled by parent (connectionError alert)
                    EmptyView()
                }
            }
        }
    }

    private func successResultView(_ result: HandshakeResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(successMessage(for: result))
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            // Success-only auto-dismisses after ~1.5s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dismiss()
            }
        }
    }

    private func successMessage(for result: HandshakeResult) -> String {
        let names = result.succeeded.map { accountLabel(for: $0) }.joined(separator: ", ")
        return "\(clientName) is now signed in for \(names)"
    }

    private func partialFailureResultView(_ result: HandshakeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(result.succeeded.count) of \(result.succeeded.count + result.failed.count) paired successfully")
                .font(.headline)
            ForEach(result.failed, id: \.signerPubkey) { failed in
                HStack {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(accountLabel(for: failed.signerPubkey))
                            .font(.subheadline)
                        Text(failed.errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Retry") {
                        retryFailed(signer: failed.signerPubkey)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }

    private func retryFailed(signer: String) {
        Task {
            let result = try? await appState.handleNostrConnect(
                parsedURI: parsedURI,
                signerPubkeys: [signer],
                permissions: composedPermissions()
            )
            if let result, result.isAllSuccess {
                // Move from failed to succeeded
                handshakeResult = HandshakeResult(
                    succeeded: handshakeResult!.succeeded + [signer],
                    failed: handshakeResult!.failed.filter { $0.signerPubkey != signer }
                )
            }
            // Else: leave failed in place; user can retry again
        }
    }
```

In `submitApproval`, set `handshakeResult` after the loop:

```swift
            let result = try await appState.handleNostrConnect(...)
            handshakeResult = result
            isConnecting = false
            if result.isAllFailure {
                connectionError = result.failed.first?.errorMessage ?? "Pairing failed"
            }
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build 2>&1 | tail -10`

Expected: build SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add Clave/Views/Home/ApprovalSheet.swift
git commit -m "$(cat <<'EOF'
feat(connect): partial-failure result UI with per-row retry

Phase 2 of multi-account NostrConnect. Three result variants
rendered after the handshake loop:

  - all-success: green checkmark + summary string, auto-dismiss
    after ~1.5s
  - partial: per-failed-account row with error message and "Retry"
    button (per-row retryFailed invokes handleNostrConnect with
    just that signer). Sheet does NOT auto-dismiss; "Done" button
    closes manually.
  - all-failure: falls through to existing connectionError alert
    (unchanged from Phase 1)

Per Decision 1: partial-failure sheet stays open until user
acknowledges. Per spec: a partial-success state is something the
user needs to actively choose to leave.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 24: Documentation updates

**Files:**
- Modify: `Clave/docs/integrations.md`
- Modify: `Clave/docs/nip46-compatibility.md`

- [ ] **Step 1: Document the `accounts=multi` URI param**

Add a new section to `Clave/docs/integrations.md`:

```markdown
## Multi-account NostrConnect (`accounts=multi`)

NostrConnect clients can request multi-account pairing by including
`accounts=multi` in their `nostrconnect://` URI. When Clave parses such a
URI, it presents a multi-select picker; the user selects N of their
accounts; Clave emits N separate `connect` acks, one per selected account,
each encrypted from that account's signing key.

### URI format

```
nostrconnect://{client_pk}?relay=wss://...&secret={secret}&accounts=multi&perms=...&name=...
```

The `accounts=multi` flag is purely additive — clients that don't recognize
it ignore it; signers (like Clave pre-Phase-2) that don't recognize it
fall back to the single-account flow, so a multi-aware client gets 1
account instead of 0. Backwards-compatible.

### Client-side requirements

A client opting in must:

1. **Keep its kind:24133 subscription open for a listening window** (~60s
   recommended) instead of completing on the first received ack. The
   "first ack → complete" default of NDK's `blockUntilReadyNostrConnect`
   and single-account `nostr-tools` flows is the specific anti-pattern to
   avoid.

2. **Parse the enriched `result` JSON.** Multi-account acks carry:

   ```json
   {"echoed_secret": "<secret>", "name": "<account label>", "picture": "<URL>"}
   ```

   Single-account acks (no `accounts=multi` flag) still emit the bare
   `<echoed_secret>` string — backwards-compatible. Multi-aware clients
   should `JSON.parse(result)` and extract `echoed_secret` for handshake
   validation.

3. **Show progress in the URI display** during the listening window
   (e.g. "1 connected, listening for more (53s)…") with a user-tappable
   "Done" button to short-circuit.

4. **Build a per-signer session map** keyed by event pubkey. Each
   received ack's event.pubkey identifies a distinct signer; subsequent
   `sign_event` RPCs are encrypted to that signer specifically.
```

- [ ] **Step 2: Update the NIP-46 client matrix**

In `Clave/docs/nip46-compatibility.md`, add a "Multi-account NostrConnect" column. Initial values:
- Tableau: ✅ (opt-in via `accounts=multi`)
- All other clients: ❌ (no opt-in)

The exact table format depends on the existing structure of the doc — match it.

- [ ] **Step 3: Commit**

```bash
git add Clave/docs/integrations.md Clave/docs/nip46-compatibility.md
git commit -m "$(cat <<'EOF'
docs(connect): document accounts=multi URI parameter

Phase 2 of multi-account NostrConnect. Adds:
  - integrations.md: new "Multi-account NostrConnect" section
    covering URI format, client opt-in requirements (60s listening
    window, JSON result parsing, progress UI, per-signer session
    map), backwards-compat guarantees
  - nip46-compatibility.md: new "Multi-account NostrConnect" column
    in the client matrix (Tableau ✅, others ❌)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 25: Phase 2 regression smoke test

**Files:** none

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test 2>&1 | tail -30`

Expected: all tests PASS (28 + new Phase 2 tests).

- [ ] **Step 2: Real-device smoke (manual)**

1. **Single-account URI (backwards compat)**: paste a URI without `accounts=multi` → single-select picker (or auto-skip if N=1) → identical to Phase 1 behavior. Confirm the bare-string `result` field is still emitted.

2. **Multi-account URI, single user**: paste a URI with `accounts=multi` on an account with only 1 Clave account → picker auto-skips → ApprovalSheet runs single-mode → 1 connect ack emitted (with JSON-shaped `result`). Confirm the client receives and parses the JSON correctly.

3. **Multi-account URI, multi user (the main case)**: with 3+ accounts on Clave, paste a multi URI → picker presents in `.multi` mode with checkboxes → all 3 default-checked (since ≤5) → tap Continue → ApprovalSheet shows "Approve 3 accounts" → tap Approve → 3 progress rows advance sequentially → 3 connect acks emitted to the client, each from a different signer → success result auto-dismisses.

4. **Cap pre-flight**: on an account that already has 5 paired clients, paste a multi URI → multi-picker shows that account disabled with "5/5 clients" badge → user can still select the other accounts → proceed normally with N-1 accounts.

5. **Partial-failure simulation**: temporarily corrupt one signer's nsec in keychain (or use an invalid signer) → multi-pair attempt → progress UI shows that signer fail → result UI shows partial-failure with Retry button → tap Retry → eventually succeeds or stays failed gracefully.

6. **Relay tolerance probe**: with 5 accounts selected, observe the kind:24133 publishes against `relay.nsec.app` (or your test relay). Check the relay's logs / accept rate. If any relay rate-limits, add the 200ms per-iteration delay per the spec's risk mitigation.

- [ ] **Step 3: Tag the Phase 2 completion point**

```bash
cd /Users/danielwyler/clave/Clave
git tag spec-multi-account-nostrconnect-phase-2-complete
```

### Task 26: Open Phase 2 PR

**Files:** none

- [ ] **Step 1: Create the Phase 2 implementation branch**

```bash
cd /Users/danielwyler/clave/Clave
git fetch origin main
git checkout -b feat/multi-account-nostrconnect-protocol origin/main

# Cherry-pick Phase 2 commits from spec/multi-account-nostrconnect:
git cherry-pick spec-multi-account-nostrconnect-phase-1-complete..spec-multi-account-nostrconnect-phase-2-complete
```

(Or squash to one commit, matching repo convention.)

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin feat/multi-account-nostrconnect-protocol
gh pr create --title "feat(connect): Phase 2 — multi-account NostrConnect protocol opt-in" --body "$(cat <<'EOF'
## Summary

Phase 2 of multi-account NostrConnect ([spec](docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md)). Builds on Phase 1 ([feat/connect-tab-restructure](https://github.com/DocNR/clave/pull/...)) which must merge first.

- Adds `accounts=multi` URI flag to `NostrConnectParser`
- `ConnectAccountPicker.multi` mode: multi-select with cap pre-flight (5/5 disabled rows)
- N-up handshake loop in `handleNostrConnect` (signature already array-shaped from Phase 1; this enables N>1)
- Enriched JSON `result` field for multi-account acks (`{echoed_secret, name, picture}`); bare-string preserved for single-account flow
- Per-iteration progress UI ("Pairing 2 of 3…", row status indicators)
- Partial-failure result screen with per-row Retry; no auto-dismiss on partial
- Documentation: `integrations.md` + `nip46-compatibility.md`

Backwards compat: every cell in the matrix is graceful-degrade or unchanged-from-today.

## Test plan
- [ ] All existing tests pass (including new Phase 2 test suites)
- [ ] Single-account URI (no flag) behaves identically to Phase 1
- [ ] Multi-account URI on single-user Clave → picker auto-skips, 1 ack emitted
- [ ] Multi-account URI on multi-user Clave (3+ accounts) → picker presents, N acks emitted
- [ ] Cap pre-flight: 5/5 accounts render disabled, user can proceed with others
- [ ] Partial-failure: bad signer → row failed → Retry → eventually succeeds
- [ ] Relay tolerance probe: 5 rapid acks on `relay.nsec.app` (and powr.build, damus.io)
- [ ] End-to-end smoke: Tableau (`/Users/danielwyler/tableau`) integration — Tableau's plan ships separately

## Tableau-side scope

Tableau's implementation of the listening-window UI + Done button + override of `nostr-tools` first-ack-complete default lives in `/Users/danielwyler/tableau/docs/superpowers/plans/` as a separate slice. That work is gated on this Clave PR shipping.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review

After plan was written, ran the checklist:

**1. Spec coverage:** Walked through each spec section and mapped to a task.

- Context / motivation → covered by spec, not a task
- Goals → ☑ Tasks 1–26 collectively
- Non-goals → ☑ Task 26 PR description reinforces scope
- Phasing → ☑ Phase 1 (tasks 1–14) and Phase 2 (tasks 15–26) split per spec
- Phase 1 IA → ☑ Tasks 5–11
- Phase 1 picker → ☑ Tasks 3, 4
- Phase 1 connect-tab UX γ → ☑ Tasks 5, 7
- Phase 1 bunker flow → ☑ Task 6
- Phase 1 NostrConnect flow → ☑ Task 7
- Phase 1 signature adoption → ☑ Tasks 1, 2
- Phase 1 what gets removed → ☑ Tasks 9, 11
- Phase 1 migration → ☑ Task 13 smoke test
- Phase 2 protocol shape → ☑ Tasks 15, 18
- Phase 2 result field shape → ☑ Task 18
- Phase 2 URI parser change → ☑ Task 15
- Phase 2 multi-mode flow listing → ☑ Tasks 17, 21
- Phase 2 picker multi-select → ☑ Task 17
- Phase 2 ApprovalSheet multi-mode → ☑ Task 20
- Phase 2 handleNostrConnect N-up → ☑ Task 19 (relies on Phase 1 Task 2 array shape)
- Phase 2 progress UI → ☑ Task 22
- Phase 2 partial-failure → ☑ Task 23
- Phase 2 cap pre-flight → ☑ Task 16
- Phase 2 backwards compat → ☑ Verified in Task 25 smoke
- Phase 2 Tableau requirements → ☑ Documented; separate plan per spec
- Documentation → ☑ Task 24
- Risks → smoke-tested in Task 25

**2. Placeholder scan:** Searched for TBD / TODO / "implement later". None present in step bodies. The only `TODO`-shaped text is the placeholder for inline help in Step 2 of Task 20 where I noted "exact existing structure of ApprovalSheet may differ" — that's an instruction to read the file, not a placeholder. Acceptable.

**3. Type consistency:**
- `HandshakeResult.FailedSigner` defined in Task 1, used consistently in Tasks 2, 19, 23
- `ConnectAccountPicker.shouldAutoSkip(accountCount:)` defined Task 4, used in Tasks 6, 7, 21
- `ConnectAccountPicker.defaultSelection(for:cappedSigners:)` defined Task 17, used internally
- `ConnectAccountPicker.canProceed(selectedCount:)` defined Task 17, used internally
- `PairAccountCapInfo.cap` defined Task 16, used in Task 17
- `SharedStorage.pairCountForSigner(_:)` defined Task 16, used in Task 17
- `LightSigner.connectAckResult(...)` defined Task 18, used in same task's Step 6
- `handleNostrConnect(parsedURI:signerPubkeys:permissions:)` (Phase 1) and `handleNostrConnect(parsedURI:signerPubkeys:permissions:progress:)` (Phase 2) — Phase 2 adds optional `progress` parameter, default `nil`, backwards-compatible at call sites
- `ApprovalSheet.boundAccountPubkeys: [String]` — used consistently from Task 20 onward (Phase 1's Task 7 still references `boundAccountPubkey` singular; the rename happens in Task 20 with call-site fixes in same task)

One inconsistency caught and corrected during review: Task 7's `ConnectTabView.swift` body uses `boundAccountPubkey: ctx.signerPubkey` (Phase 1 single-mode), but `ApprovalSheet`'s API is migrated to `boundAccountPubkeys` in Task 20. The Task 20 step explicitly updates this call site — verified.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-10-multi-account-nostrconnect-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration. Use `superpowers:subagent-driven-development` against this plan.

2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
