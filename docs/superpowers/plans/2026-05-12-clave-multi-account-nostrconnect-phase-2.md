# Clave Phase 2 — Multi-Account NostrConnect (`accounts=multi`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Context

Clave Phase 1 (PRs [#52](https://github.com/DocNR/clave/pull/52) + [#53](https://github.com/DocNR/clave/pull/53), tag `v0.2.0-build79`) already shipped the Connect tab + `ConnectAccountPicker` unification + the array-shaped `handleNostrConnect(parsedURI:, signerPubkeys: [String], permissions:) -> HandshakeResult` signature. Phase 1 always passes a 1-element array; semantics identical to pre-Phase-1.

**Phase 2** layers the protocol opt-in on Phase 1's foundation: one optional URI parameter (`accounts=multi`) lets a NostrConnect client receive N parallel signer sessions in one user flow. When a multi-aware client sends a URI with the flag, Clave's picker presents in `.multi` mode (checkboxes, N≥1 selection), the user picks accounts, and Clave runs the existing handshake N times sequentially under one `UIBackgroundTask` — one kind:24133 `connect` ack per selected account, each carrying JSON `result` metadata.

The motivating client is **Spectr** (DocNR/spectr — TweetDeck-style multi-column Nostr reader, current branch `feature/multi-account-nostrconnect`). Spectr's Slice MA has shipped 7 implementation tasks and is waiting on this Clave Phase 2 to land for end-to-end verification (its Task 8 has 9 sub-checks ready against a real Phase 2 build).

**Goal:** Implement spec §"Phase 2" from `/Users/danielwyler/Clave/Clave/docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md`.

**Architecture:** Pure protocol-extension layer over Phase 1's foundation. Parser gains one Bool. Picker gains `.multi` rendering. `handleNostrConnect` enables the N>1 path (loop body already exists; iteration semantics already correct). LightSigner gains a JSON ack-result helper. ApprovalSheet gains multi-mode header + progress UI + partial-failure UI. ConnectTabView routes the flag through to multi-picker → multi-approval. Two docs files documented. No new third-party deps; no proxy changes; no new event kinds.

**Tech Stack:** Swift / SwiftUI on iOS, XCTest, existing Clave primitives (`AppState`, `SharedStorage`, `LightSigner`, `LightCrypto`, `LightEvent`, `NostrConnectParser`, `HandshakeResult`, `ConnectAccountPicker`). No new third-party deps.

**Branch:** `feature/multi-account-nostrconnect-phase-2` (NEW). Branch off `main` at `cd34546` or current. Implementation lands as ONE PR. Spec/plan branch (already merged) is the planning artifact; this branch references it.

**Verification model:** Clave runs unit tests via `xcodebuild`. Build + tests must pass per task (red → green → commit). Manual smoke tests on real device gate the PR. Pre-commit hooks may enforce linting — do NOT skip them; if a hook fails, fix the underlying issue.

**Commit model:** Per-task commits (TDD-style: red → green → commit). Conventional-commits format matching Phase 1: `feat(connect): ...`, `refactor(connect): ...`, `test(connect): ...`, `docs(connect): ...`. Each commit ends with the `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.

**Reading order:** Read the spec §"Phase 2" end-to-end before starting Task 1. Reference Spectr's spec (`/Users/danielwyler/tableau/docs/superpowers/specs/2026-05-12-spectr-multi-account-nostrconnect-design.md`) for the consumer side of the wire — particularly its accumulator (`nostrConnectionLoginMulti` in `login-flows.ts`) which trusts `total` for auto-finalize.

**Spec-divergence to track + amend (Task 1):** The 2026-05-10 spec's JSON example at §"`result` field shape" reads `{echoed_secret, name, picture}` — no `total`. Spectr's accumulator parses `total` and uses it for auto-finalize. Implementation here emits `{echoed_secret, name?, picture?, total}` where `total` is the picker-selected count, matching Spectr's expectation exactly. Task 1 amends the spec to match before any code lands. The `total` MUST equal picker selection count exactly — over-promising risks Spectr finalizing late (it auto-closes the subscription on `count == total`); under-promising would orphan late acks.

**Save plan to (after exit-plan-mode):** `/Users/danielwyler/Clave/Clave/docs/superpowers/plans/2026-05-12-clave-multi-account-nostrconnect-phase-2.md` — the canonical project location. (This file is the plan-mode working copy.)

---

## File structure

**Created:**
- `Clave/Models/PairAccountCapInfo.swift` — small value type carrying `(signerPubkey, currentPairCount, isAtCap, remaining)` for picker pre-flight
- `ClaveTests/NostrConnectParserMultiAccountTests.swift` — `isMultiAccount` parser extension
- `ClaveTests/PairAccountCapInfoTests.swift` — cap value-type
- `ClaveTests/ConnectAccountPickerMultiModeTests.swift` — multi-mode defaults + cap exclusion
- `ClaveTests/LightSignerMultiAccountResultTests.swift` — JSON result emission
- `ClaveTests/AppStateMultiAccountHandshakeTests.swift` — N-up loop semantics
- `Clave/docs/integrations.md` — new file; documents `accounts=multi` URI param + listening-window expectation + JSON `result` shape for client integrators

**Modified:**
- `Clave/docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md` — amend `total` into JSON example (Task 1)
- `Clave/Shared/NostrConnectParser.swift` — add `isMultiAccount: Bool` on `ParsedURI`; parse from `accounts=multi` query param
- `Clave/Shared/SharedStorage.swift` — add `pairCountForSigner(_ signerPubkeyHex: String) -> Int` helper (computed from existing `getConnectedClients(for:)`)
- `Clave/Views/Connect/ConnectAccountPicker.swift` — implement `.multi` case (checkboxes, default selection rules, cap-disabled rows, "Continue with N accounts" button)
- `Clave/Shared/LightSigner.swift` — add `connectAckResult(isMultiAccount:, echoedSecret:, accountName:, accountPicture:, total:) -> String` static helper
- `Clave/AppState+NostrConnect.swift` — wire `connectAckResult(...)` into the ack-build site (line ~131); add optional progress callback param to `handleNostrConnect`
- `Clave/Views/Home/ApprovalSheet.swift` — migrate `boundAccountPubkey: String?` → `boundAccountPubkeys: [String]`; multi-mode header + selected-accounts inline list; progress UI; partial-failure result UI
- `Clave/Views/Connect/ConnectTabView.swift` — branch `handleParsed` on `parsedURI.isMultiAccount`; multi-picker sheet; multi-mode approval context
- `Clave/docs/nip46-compatibility.md` — add "Multi-account NostrConnect" column to client matrix (Spectr ✅, others ❌)
- `Clave/Clave.xcodeproj/project.pbxproj` — bump `CURRENT_PROJECT_VERSION` from 79 to 80 (Task 13)

**Deleted:** none.

---

## Phase 2 acceptance criteria (from spec §"Plan + verification")

- URI parser sets `isMultiAccount = true` for `accounts=multi` URIs and `false` otherwise (unit test).
- Picker `.multi` mode renders correctly with cap-disabled rows (unit test + smoke).
- `handleNostrConnect` N-up loop returns correct `HandshakeResult` for all-success / partial / all-failure (unit test).
- LightSigner emits JSON `result` containing `echoed_secret`, optional `name`/`picture`, and `total: <selectedCount>` for multi-account acks; single-account flow keeps bare-string `result` (unit test).
- Backwards-compat: old single-account URI through new Clave → exactly today's behavior (smoke test).
- End-to-end with Spectr: paste multi URI in Clave, select 2+ accounts, approve, observe Spectr receive N acks within listening window and surface N accounts. Spectr Task 8's 9 sub-checks green (integration smoke against Spectr's `feature/multi-account-nostrconnect`).
- Manual probe of relay tolerance for rapid N kind:24133 events on `#p:client_pk` against `wss://relay.nsec.app`, `wss://relay.damus.io`, `wss://relay.powr.build`. If any rate-limits, add a 200ms inter-iteration delay inside the loop and re-probe.

---

## Task 1: Branch off main + spec amendment for `total` field

**Files:**
- Branch: create `feature/multi-account-nostrconnect-phase-2` off `main`
- Modify: `Clave/docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md`

- [ ] **Step 1: Create the feature branch**

```bash
cd /Users/danielwyler/Clave/Clave
git checkout main
git pull --ff-only
git checkout -b feature/multi-account-nostrconnect-phase-2
```

Expected: clean branch off latest `main`; no working-tree changes.

- [ ] **Step 2: Amend the spec to add `total` to the JSON example**

Edit `Clave/docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md` §"`result` field shape — enriched per-ack metadata" (around line 224–238). Replace the JSON example:

Before:
```json
{
  "echoed_secret": "abc123...",
  "name": "alice",
  "picture": "https://..."
}
```

After:
```json
{
  "echoed_secret": "abc123...",
  "name": "alice",
  "picture": "https://...",
  "total": 3
}
```

Add a new paragraph immediately after the JSON block:

```markdown
`total` is the count of accounts the user selected in Clave's `.multi`-mode picker — the number of acks Clave will emit for this `(client_pk, secret)` handshake. **Every ack in the batch carries the same `total` value**, so a client receiving any one ack already knows how many to expect. Multi-aware clients (e.g. Spectr's `nostrConnectionLoginMulti` accumulator) use `total` for an auto-finalize signal — closing the subscription as soon as `count == total`, rather than waiting for the 60s timeout. **`total` MUST equal the picker selection count exactly.** Over-promising (announcing `total: 4` but only 3 acks land) is recoverable via the 60s timeout but creates an "is the missing one still loading?" UX moment. Under-promising (announcing `total: 2` when the user selected 3) would orphan the third ack — multi-aware clients close their subscription on auto-finalize, dropping later-arriving acks.
```

- [ ] **Step 3: Commit**

```bash
git add Clave/docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md
git commit -m "$(cat <<'EOF'
docs(spec): amend Phase 2 JSON result shape with total field

The 2026-05-10 spec's "result field shape" example showed
{echoed_secret, name, picture}. Spectr's accumulator
(nostrConnectionLoginMulti in login-flows.ts) parses an additional
`total` field and uses it for auto-finalize — closing the
kind:24133 subscription as soon as the accumulated ack count
matches `total`, rather than waiting for the 60s timeout.

Amends the spec to:
  - add `total: 3` to the JSON example
  - document that every ack in the batch carries the same `total`
  - require `total` to equal picker selection count exactly
  - explain over-promise (recoverable via timeout) vs under-promise
    (orphans late acks — auto-finalize closes the subscription)

Aligns the spec with both this Phase 2 implementation and Spectr's
shipped (unmerged) accumulator. The pre-amendment JSON example was
incomplete; this corrects it before Phase 2 lands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `isMultiAccount` to `ParsedURI`

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
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.example.com&secret=s&accounts=multi"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertTrue(parsed.isMultiAccount)
    }

    func testAccountsMultiFlagAbsent() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertFalse(parsed.isMultiAccount)
    }

    func testAccountsParamWithDifferentValueIgnored() throws {
        // Only `accounts=multi` enables the flag. Other values (eg
        // `accounts=single`, `accounts=2`) parse to false — forward-compat
        // with any future scheme that overloads this query key.
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.example.com&secret=s&accounts=single"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertFalse(parsed.isMultiAccount)
    }

    func testAccountsMultiPreservesOtherFields() throws {
        let uri = "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.example.com&secret=s&accounts=multi&name=Spectr&perms=sign_event%3A1"
        let parsed = try NostrConnectParser.parse(uri)
        XCTAssertTrue(parsed.isMultiAccount)
        XCTAssertEqual(parsed.name, "Spectr")
        XCTAssertEqual(parsed.requestedPerms, ["sign_event:1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild -workspace Clave.xcworkspace -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:ClaveTests/NostrConnectParserMultiAccountTests 2>&1 | tail -15
```

Expected: build FAILS with `value of type 'NostrConnectParser.ParsedURI' has no member 'isMultiAccount'`.

- [ ] **Step 3: Add `isMultiAccount` to `ParsedURI` + parser logic**

In `Clave/Shared/NostrConnectParser.swift`:

Add the field to `ParsedURI` (the new field appended at the end, after `suggestedTrustLevel`):
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

In `parse(_:)`, after the `imageURL` parsing and before the `suggestedTrustLevel` computation, add:
```swift
        let accountsParam = queryItems.first(where: { $0.name == "accounts" })?.value
        let isMultiAccount = accountsParam == "multi"
```

Update the final `ParsedURI(...)` constructor call to pass the new field:
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

```bash
xcodebuild -workspace Clave.xcworkspace -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:ClaveTests/NostrConnectParserMultiAccountTests 2>&1 | tail -15
```

Expected: 4 tests PASS.

Also re-run the existing parser suite to verify no regression:
```bash
xcodebuild ... test -only-testing:ClaveTests/NostrConnectParserTests 2>&1 | tail -10
```

Expected: all existing tests PASS (no breaks from the new field).

- [ ] **Step 5: Commit**

```bash
git add Clave/Shared/NostrConnectParser.swift ClaveTests/NostrConnectParserMultiAccountTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): parse accounts=multi URI flag in NostrConnectParser

Phase 2 of multi-account NostrConnect. Adds isMultiAccount: Bool
to ParsedURI; parser sets it iff the URI carries accounts=multi.
Other accounts= values (e.g. accounts=single, accounts=2) parse to
false — forward-compat with future schemes that overload this key.

All existing ParsedURI fields preserved; existing parser test
suite unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `PairAccountCapInfo` + `pairCountForSigner` helper

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
        // Cap is the single source of truth — matches the proxy's
        // pair-client enforcement (5 pairs/signer per the Phase 1
        // multi-account sprint).
        XCTAssertEqual(PairAccountCapInfo.cap, 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild ... test -only-testing:ClaveTests/PairAccountCapInfoTests 2>&1 | tail -10
```

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
```

- [ ] **Step 4: Add the `SharedStorage` helper**

In `Clave/Shared/SharedStorage.swift`, add this static method (alongside the existing `getConnectedClients(for:)` accessor at ~line 192):

```swift
    /// Count of distinct paired clients for a given signer pubkey. Used by
    /// the multi-mode picker to pre-flight the per-signer 5-pair cap.
    static func pairCountForSigner(_ signerPubkeyHex: String) -> Int {
        getConnectedClients(for: signerPubkeyHex).count
    }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild ... test -only-testing:ClaveTests/PairAccountCapInfoTests 2>&1 | tail -10
```

Expected: 4 tests PASS.

- [ ] **Step 6: Build the whole project to verify no regressions**

```bash
xcodebuild -workspace Clave.xcworkspace -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

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
proxy is the source of truth; this is a client-side UX surface for
the same constraint.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Implement `.multi` mode in `ConnectAccountPicker`

**Files:**
- Modify: `Clave/Views/Connect/ConnectAccountPicker.swift`
- Test: `ClaveTests/ConnectAccountPickerMultiModeTests.swift`

The Phase 1 picker has a `.multi` enum case that currently falls back to `.single` rendering. This task implements the actual multi-select rendering, default-selection rule, cap-disabled rows, and "Continue with N accounts" button.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/ConnectAccountPickerMultiModeTests.swift`:

```swift
import XCTest
@testable import Clave

/// Pure-logic tests for ConnectAccountPicker .multi mode behavior. UI
/// rendering is verified in a manual smoke test (a SwiftUI render in a
/// unit-test target requires extra plumbing; the logic helpers are pure
/// and easier to assert directly).
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
        // are default-checked. Capped rows would just have to be unchecked
        // by the user anyway — surfacing them as pre-selected is bad UX.
        let pubkeys = ["pk1", "pk2", "pk3"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: ["pk2"]
        )
        XCTAssertEqual(selected, Set(["pk1", "pk3"]))
    }

    func testDefaultSelection_MoreThan5_CappedExcluded() {
        // >5 accounts → default-none, regardless of capping. (Capped set
        // here is irrelevant; still produces empty default.)
        let pubkeys = ["pk1", "pk2", "pk3", "pk4", "pk5", "pk6"]
        let selected = ConnectAccountPicker.defaultSelection(
            for: pubkeys,
            cappedSigners: ["pk3"]
        )
        XCTAssertEqual(selected, Set())
    }

    func testCanProceed_RequiresAtLeastOneSelected() {
        XCTAssertFalse(ConnectAccountPicker.canProceed(selectedCount: 0))
        XCTAssertTrue(ConnectAccountPicker.canProceed(selectedCount: 1))
        XCTAssertTrue(ConnectAccountPicker.canProceed(selectedCount: 5))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild ... test -only-testing:ClaveTests/ConnectAccountPickerMultiModeTests 2>&1 | tail -10
```

Expected: build FAILS — `defaultSelection` / `canProceed` not found.

- [ ] **Step 3: Add the static helper functions**

In `Clave/Views/Connect/ConnectAccountPicker.swift`, add inside the struct (alongside any existing `shouldAutoSkip` helper):

```swift
    /// Default selection set for `.multi` mode.
    /// Rules (matches spec §"ConnectAccountPicker — multi-select mode"):
    ///   - if total accounts ≤ 5: all non-capped accounts are pre-checked
    ///   - if total accounts > 5: none are pre-checked (deliberate
    ///     selection on large account sets — avoids accidental-bulk-pair
    ///     surprise per spec §"Risks #3")
    /// Capped accounts are NEVER pre-checked regardless of total count.
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

    /// Whether the Continue button is enabled — at least 1 account must
    /// be selected. Used by the multi-mode rendering.
    static func canProceed(selectedCount: Int) -> Bool {
        selectedCount >= 1
    }
```

- [ ] **Step 4: Implement the multi-mode SwiftUI rendering**

This is the largest change. Modify `ConnectAccountPicker.swift` to branch row rendering and add the Continue button. Preserve the existing single-mode behavior exactly — only the `case .multi` branches are new.

Add multi-mode state (alongside any existing `@State` properties):

```swift
    @State private var multiSelected: Set<String> = []
    @State private var cappedSigners: Set<String> = []
```

Replace `body` with a version that branches on mode and adds the Continue button only for `.multi`:

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
        .onAppear(perform: setupMultiModeDefaults)
    }

    private func setupMultiModeDefaults() {
        guard case .multi = mode else { return }
        cappedSigners = Set(
            appState.accounts
                .map(\.pubkeyHex)
                .filter { PairAccountCapInfo(
                    signerPubkey: $0,
                    currentPairCount: SharedStorage.pairCountForSigner($0)
                ).isAtCap }
        )
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
            Text(continueLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!Self.canProceed(selectedCount: multiSelected.count))
    }

    private var continueLabel: String {
        let n = multiSelected.count
        return "Continue with \(n) account\(n == 1 ? "" : "s")"
    }
```

Update the multi-mode header (existing placeholder header from Phase 1 likely says something generic; update to spec wording per §"ConnectAccountPicker — multi-select mode"):

```swift
    private var navigationTitle: String {
        switch mode {
        case .single:
            return "Choose account"
        case .multi:
            return "Choose accounts"
        }
    }

    // headerBlock: extend to switch on mode for accurate copy
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch mode {
            case .single:
                Text("Choose the identity to use for **\(clientNameOrFallback)**.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .multi:
                Text("**\(clientNameOrFallback)** wants to connect to multiple accounts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clientNameOrFallback: String {
        parsedURI?.name ?? "this app"
    }
```

(If these helpers already exist in Phase 1's `ConnectAccountPicker.swift`, keep their existing logic and just add the `.multi` branch.)

Replace `accountRow(for:)` to render checkboxes + cap badges in `.multi` mode (preserving the `.single` tap-to-pick behavior):

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
                        .background(Color(.tertiarySystemGroupedBackground),
                                    in: Capsule())
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(isCapped ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isCapped)
    }
```

Notes:
- `AvatarView`, `AccountTheme`, `account.displayLabel` are existing Phase 1 primitives — do NOT re-declare; reference verbatim.
- If the existing Phase 1 `accountRow` uses different visual primitives, preserve them and just add the multi-mode branching (checkbox icon, cap badge, disabled state).

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild ... test -only-testing:ClaveTests/ConnectAccountPickerMultiModeTests 2>&1 | tail -10
```

Expected: 5 tests PASS.

- [ ] **Step 6: Re-run the existing auto-skip tests**

```bash
xcodebuild ... test -only-testing:ClaveTests/ConnectAccountPickerAutoSkipTests 2>&1 | tail -10
```

Expected: all existing tests PASS (Phase 1 behavior preserved).

- [ ] **Step 7: Build to verify**

```bash
xcodebuild build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Clave/Views/Connect/ConnectAccountPicker.swift \
        ClaveTests/ConnectAccountPickerMultiModeTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): implement ConnectAccountPicker .multi mode rendering

Phase 2 of multi-account NostrConnect. Adds:
  - Checkbox-style multi-select rendering with hap-tic feedback
  - Default-selection rules (per spec §"Risks #3"):
      ≤5 accounts → all non-capped pre-checked
      >5 accounts → none pre-checked (deliberate selection)
  - Cap pre-flight: rows where signer is at the 5-pair cap render
    disabled with a "5/5 clients" badge inline
  - "Continue with N accounts" button at the sheet bottom; disabled
    when 0 selected
  - Mode-specific header copy:
      .single: "Choose the identity to use for X."
      .multi:  "X wants to connect to multiple accounts."

Picker stays a sheet step BEFORE ApprovalSheet — the two-step flow
("which accounts" → "what permissions + approve") is preserved
across single and multi modes (spec §"Phase 2 — NostrConnect flow
in multi mode" step 5).

Capped signers are excluded from default-checked sets — surfacing
them as pre-selected would just create extra uncheck taps.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `LightSigner.connectAckResult(...)` helper

**Files:**
- Modify: `Clave/Shared/LightSigner.swift`
- Test: `ClaveTests/LightSignerMultiAccountResultTests.swift`

This task adds a pure helper. Task 6 wires it into the ack-build site. Splitting these keeps each commit focused.

- [ ] **Step 1: Write the failing test**

Create `ClaveTests/LightSignerMultiAccountResultTests.swift`:

```swift
import XCTest
@testable import Clave

/// Tests for LightSigner.connectAckResult(...) — the per-ack `result`
/// field builder. Single-account path emits bare-string secret;
/// multi-account path emits JSON {echoed_secret, name?, picture?, total}.
final class LightSignerMultiAccountResultTests: XCTestCase {

    func testSingleAccount_isBareSecret() {
        // Single-account flow (isMultiAccount: false) emits the existing
        // string-secret format — preserves backwards compat for every
        // existing client, including those that string-compare result.
        let result = LightSigner.connectAckResult(
            isMultiAccount: false,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: "https://example.com/p.png",
            total: 1
        )
        XCTAssertEqual(result, "abc123")
    }

    func testMultiAccount_isJSON_withAllFields() throws {
        // Multi-account flow emits a JSON object so the client can render
        // account labels without a follow-up kind:0 fetch.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: "https://example.com/p.png",
            total: 3
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertEqual(json["name"] as? String, "alice")
        XCTAssertEqual(json["picture"] as? String, "https://example.com/p.png")
        XCTAssertEqual(json["total"] as? Int, 3)
    }

    func testMultiAccount_omitsNilName() throws {
        // Account without a cached profile — name absent — but
        // echoed_secret + total always present.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: nil,
            accountPicture: "https://example.com/p.png",
            total: 2
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertNil(json["name"])
        XCTAssertEqual(json["picture"] as? String, "https://example.com/p.png")
        XCTAssertEqual(json["total"] as? Int, 2)
    }

    func testMultiAccount_omitsNilPicture() throws {
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: "alice",
            accountPicture: nil,
            total: 2
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertEqual(json["name"] as? String, "alice")
        XCTAssertNil(json["picture"])
        XCTAssertEqual(json["total"] as? Int, 2)
    }

    func testMultiAccount_omitsEmptyName() throws {
        // Empty-string name is treated identically to nil — no point
        // emitting `"name": ""` for a client.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: "",
            accountPicture: nil,
            total: 1
        )
        let json = try parseJSONObject(result)
        XCTAssertNil(json["name"])
        XCTAssertEqual(json["total"] as? Int, 1)
    }

    func testMultiAccount_totalAlwaysPresent() throws {
        // Even with name + picture both nil, `total` is always emitted —
        // Spectr's accumulator uses it for auto-finalize.
        let result = LightSigner.connectAckResult(
            isMultiAccount: true,
            echoedSecret: "abc123",
            accountName: nil,
            accountPicture: nil,
            total: 5
        )
        let json = try parseJSONObject(result)
        XCTAssertEqual(json["echoed_secret"] as? String, "abc123")
        XCTAssertEqual(json["total"] as? Int, 5)
    }

    // MARK: - Helpers

    private func parseJSONObject(_ str: String) throws -> [String: Any] {
        guard let data = str.data(using: .utf8) else {
            XCTFail("Result is not utf8")
            return [:]
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Result is not a JSON object: \(str)")
            return [:]
        }
        return obj
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild ... test -only-testing:ClaveTests/LightSignerMultiAccountResultTests 2>&1 | tail -10
```

Expected: build FAILS — `connectAckResult` not found.

- [ ] **Step 3: Add the helper**

In `Clave/Shared/LightSigner.swift`, add a static method (placement: near the bottom of the type, or alongside other response-building helpers):

```swift
    /// Build the `result` field for a NIP-46 `connect` ack.
    ///
    /// Single-account (`isMultiAccount: false`): bare echoed-secret string,
    /// matches today's behavior. Backwards-compatible with all existing
    /// clients including ones that string-compare `result == secret`.
    ///
    /// Multi-account (`isMultiAccount: true`): JSON object
    /// `{echoed_secret, name?, picture?, total}`. Lets multi-aware clients
    /// (Spectr) render account labels without a follow-up kind:0 fetch and
    /// auto-finalize their listening window on `count == total`.
    ///
    /// `total` MUST equal the picker's selected-count exactly per spec.
    /// Pass the same value on every iteration of the N-up handshake loop
    /// (each ack in the batch carries the same `total`).
    static func connectAckResult(
        isMultiAccount: Bool,
        echoedSecret: String,
        accountName: String?,
        accountPicture: String?,
        total: Int
    ) -> String {
        guard isMultiAccount else {
            return echoedSecret
        }
        // Build heterogeneous JSON object: String fields + Int `total`.
        var fields: [String: Any] = [
            "echoed_secret": echoedSecret,
            "total": total
        ]
        if let name = accountName, !name.isEmpty {
            fields["name"] = name
        }
        if let picture = accountPicture, !picture.isEmpty {
            fields["picture"] = picture
        }
        // Sorted keys → deterministic output (helps test assertions + log
        // diffing).
        guard let data = try? JSONSerialization.data(
                withJSONObject: fields,
                options: [.sortedKeys]
              ),
              let str = String(data: data, encoding: .utf8) else {
            // Fallback: if JSON serialization fails (shouldn't happen for
            // plain String + Int fields), degrade to bare secret rather
            // than breaking the handshake.
            return echoedSecret
        }
        return str
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild ... test -only-testing:ClaveTests/LightSignerMultiAccountResultTests 2>&1 | tail -10
```

Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Clave/Shared/LightSigner.swift \
        ClaveTests/LightSignerMultiAccountResultTests.swift
git commit -m "$(cat <<'EOF'
feat(connect): LightSigner.connectAckResult helper for multi-account

Phase 2 of multi-account NostrConnect. Adds a static helper that
builds the `result` field for a NIP-46 connect ack:

  - isMultiAccount false → bare echoed-secret string (today's
    behavior, backwards-compatible with every existing client
    including ones that string-compare result == secret)
  - isMultiAccount true → JSON {echoed_secret, name?, picture?, total}

`total` is always present in the multi-account JSON shape and MUST
equal the picker's selected-count exactly per spec. Spectr's
accumulator uses it for auto-finalize (closes the kind:24133
subscription when accumulated count matches total).

Sorted-keys output for deterministic JSON + easier log diffing.
JSON serialization-failure path degrades to bare secret rather
than breaking the handshake.

This task adds the helper only; Task 6 wires it into the ack-build
site in AppState+NostrConnect.swift.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `connectAckResult(...)` into the ack-build site

**Files:**
- Modify: `Clave/AppState+NostrConnect.swift`

The Phase 1 explorer surveyed `Clave/AppState+NostrConnect.swift:~131-132` as the ack-build site, with the current line shape: `["id": responseId, "result": parsedURI.secret]`.

- [ ] **Step 1: Read the current ack-build site to confirm shape**

```bash
sed -n '120,150p' /Users/danielwyler/Clave/Clave/Clave/AppState+NostrConnect.swift
```

Expected: a line like `let responseDict: [String: Any] = ["id": responseId, "result": parsedURI.secret]` inside `runSingleConnect` (or wherever the connect-ack is built post-Phase-1).

- [ ] **Step 2: Replace the hard-coded secret with `connectAckResult(...)`**

In `Clave/AppState+NostrConnect.swift`, modify `runSingleConnect(parsedURI:, signerPubkey:, permissions:)`. The function already has access to `parsedURI` (which now has `isMultiAccount`) and `signerPubkey`. Replace the response-dict construction:

Before:
```swift
            let responseDict: [String: Any] = ["id": responseId, "result": parsedURI.secret]
```

After:
```swift
            // Resolve account profile for enriched JSON ack (multi only)
            let account = accounts.first(where: { $0.pubkeyHex == signerPubkey })
            let resultField = LightSigner.connectAckResult(
                isMultiAccount: parsedURI.isMultiAccount,
                echoedSecret: parsedURI.secret,
                accountName: account?.profile?.displayName,
                accountPicture: account?.profile?.pictureURL,
                total: signerPubkeysCount   // injected from caller; see Step 3
            )
            let responseDict: [String: Any] = ["id": responseId, "result": resultField]
```

Note the field-name mapping: Account.profile property is `pictureURL` (Phase 1 explorer confirmed), but the JSON output key is `picture` — that mapping happens inside `connectAckResult` via parameter name `accountPicture`.

- [ ] **Step 3: Thread `total` through `runSingleConnect`**

`total` is the picker's selected count, known at the outer `handleNostrConnect` boundary as `signerPubkeys.count`. Pass it down:

In `handleNostrConnect`, before/inside the iteration loop:
```swift
        let total = signerPubkeys.count
        for signerPubkey in signerPubkeys {
            do {
                try await runSingleConnect(
                    parsedURI: parsedURI,
                    signerPubkey: signerPubkey,
                    permissions: permissions,
                    total: total   // NEW
                )
                succeeded.append(signerPubkey)
            } catch {
                failed.append(HandshakeResult.FailedSigner(
                    signerPubkey: signerPubkey,
                    errorMessage: error.localizedDescription
                ))
            }
        }
```

Update `runSingleConnect`'s signature to accept `total`:
```swift
    private func runSingleConnect(
        parsedURI: NostrConnectParser.ParsedURI,
        signerPubkey: String,
        permissions: ClientPermissions,
        total: Int
    ) async throws {
        // ... existing body ...
    }
```

Replace the placeholder `signerPubkeysCount` in Step 2's snippet with `total`.

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual sanity check — single-account flow unchanged**

Pair a single-account NostrConnect from any existing client (URI WITHOUT `accounts=multi`). Verify the ack arrives and client handshake completes as today. This proves `isMultiAccount: false` path emits bare secret unchanged.

(This is a manual check — no automated test. The unit tests in Task 5 cover the helper's logic; this step verifies the integration into the live response dict.)

- [ ] **Step 6: Commit**

```bash
git add Clave/AppState+NostrConnect.swift
git commit -m "$(cat <<'EOF'
feat(connect): wire connectAckResult into the connect-ack response

Phase 2 of multi-account NostrConnect. Replaces the hard-coded
`parsedURI.secret` in runSingleConnect's response dict with
LightSigner.connectAckResult(isMultiAccount:, echoedSecret:,
accountName:, accountPicture:, total:).

  - isMultiAccount false → bare-secret response (today's behavior,
    bit-identical to pre-Phase-2 — verified by single-account
    manual smoke)
  - isMultiAccount true → JSON {echoed_secret, name?, picture?, total}
    with total = signerPubkeys.count (the picker's selected-count
    threaded through handleNostrConnect)

Account profile resolution: Account.profile.displayName for `name`,
Account.profile.pictureURL for `picture` (mapped from Swift's
`pictureURL` to JSON's `picture` key inside connectAckResult).

runSingleConnect signature gains `total: Int`. handleNostrConnect
computes total = signerPubkeys.count once at the top of the loop
and passes it down — every ack in the batch carries the same
total value.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add N-up handshake loop semantics tests

**Files:**
- Test: `ClaveTests/AppStateMultiAccountHandshakeTests.swift`

The N-up loop body already exists from Phase 1 (Phase 1 always passed a 1-element array; the iteration is general-purpose). This task adds tests that verify the loop correctly accumulates `HandshakeResult` for N>1 inputs.

- [ ] **Step 1: Write the test**

Create `ClaveTests/AppStateMultiAccountHandshakeTests.swift`:

```swift
import XCTest
@testable import Clave

/// N-up handshake loop semantics. Live-relay handshake is impractical to
/// unit test (requires real relay + nsec). These tests verify the
/// loop-coordination layer: HandshakeResult accumulation, partial-failure
/// shape, empty-input boundary.
final class AppStateMultiAccountHandshakeTests: XCTestCase {

    @MainActor
    func testEmptyArrayThrowsAtBoundary() async throws {
        let appState = AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.example.com&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "aabbccdd",
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

    @MainActor
    func testAllFailure_AccumulatesAllPubkeysIntoFailed() async throws {
        // Two signer pubkeys that don't exist in the keychain → every
        // iteration throws at the nsec-load step → both end up in
        // HandshakeResult.failed with correct signerPubkey attribution.
        let appState = AppState()
        let dummyURI = try NostrConnectParser.parse(
            "nostrconnect://aabbccdd?relay=wss%3A%2F%2Frelay.invalid.test&secret=s"
        )
        let perms = ClientPermissions(
            pubkey: "aabbccdd",
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
        XCTAssertFalse(result.isPartialFailure)
        XCTAssertFalse(result.isAllSuccess)
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
xcodebuild ... test -only-testing:ClaveTests/AppStateMultiAccountHandshakeTests 2>&1 | tail -10
```

Expected: 2 tests PASS.

If tests fail with anything other than the expected `ClaveError.noSignerKey` / 2-element failed array, the issue is in Phase 1's loop body or `runSingleConnect` error propagation — investigate before continuing.

- [ ] **Step 3: Re-run the Phase 1 handshake-signature tests as a regression check**

```bash
xcodebuild ... test -only-testing:ClaveTests/AppStateHandshakeSignatureTests 2>&1 | tail -10
```

Expected: all Phase 1 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add ClaveTests/AppStateMultiAccountHandshakeTests.swift
git commit -m "$(cat <<'EOF'
test(connect): N-up handshake loop semantics (multi-account)

Phase 2 of multi-account NostrConnect. Tests verify that the
array-shape handleNostrConnect signature (Phase 1's refactor)
correctly accumulates per-iteration results into HandshakeResult:

  - empty signerPubkeys throws ClaveError.noSignerKey at the
    boundary (Phase 1 invariant, preserved under Phase 2)
  - 2 nonexistent signers → 2 entries in HandshakeResult.failed,
    each carrying its own signerPubkey for partial-failure UX
    attribution. isAllFailure true, isPartialFailure false,
    isAllSuccess false.

Live-relay handshake assertions remain in the manual smoke test
(Task 14). Loop body is unchanged from Phase 1 — this commit
verifies the N>1 case lands cleanly through the existing scaffold.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Migrate `ApprovalSheet` to `boundAccountPubkeys: [String]` + multi-mode rendering

**Files:**
- Modify: `Clave/Views/Home/ApprovalSheet.swift`
- Modify: every caller of `ApprovalSheet(...)` (caller migration)

The Phase 1 explorer reports `ApprovalSheet` currently takes `boundAccountPubkey: String?` (single). Migrate to `boundAccountPubkeys: [String]` and add multi-mode rendering. This task does the type migration + header + selected-accounts list + Approve button copy. Progress UI (Task 10) and partial-failure UI (Task 11) come in subsequent tasks.

- [ ] **Step 1: Read the current ApprovalSheet signature**

```bash
sed -n '15,40p' /Users/danielwyler/Clave/Clave/Clave/Views/Home/ApprovalSheet.swift
```

Expected: an init like `init(parsedURI:..., boundAccountPubkey: String?, ...)`.

- [ ] **Step 2: Migrate the type signature**

In `Clave/Views/Home/ApprovalSheet.swift`, change:
```swift
struct ApprovalSheet: View {
    let parsedURI: NostrConnectParser.ParsedURI
    let boundAccountPubkeys: [String]   // was: boundAccountPubkey: String?
    let onApprove: (ClientPermissions) -> Void
    // ... existing properties ...

    private var isMulti: Bool { boundAccountPubkeys.count > 1 }
```

If the existing `boundAccountPubkey` was optional (`String?`), the migration shape is `[String]` — callers that previously passed `nil` should now pass `[]`, but in practice ApprovalSheet is only invoked after picker selection so the array is always non-empty.

- [ ] **Step 3: Update headers to branch on `isMulti`**

Replace the existing single-header block:
```swift
    private var headerBlock: some View {
        if isMulti {
            multiHeader
        } else {
            singleHeader
        }
    }

    private var singleHeader: some View {
        SigningAsHeader(signerPubkeyHex: boundAccountPubkeys.first ?? "")
        // ... existing single-mode header content ...
    }

    private var multiHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(clientName) is requesting to sign for \(boundAccountPubkeys.count) accounts")
                .font(.title3.weight(.semibold))
            selectedAccountsInlineList
        }
    }

    private var selectedAccountsInlineList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(boundAccountPubkeys, id: \.self) { pubkey in
                    accountChip(pubkey: pubkey)
                }
            }
        }
    }

    private func accountChip(pubkey: String) -> some View {
        let account = appState.accounts.first(where: { $0.pubkeyHex == pubkey })
        return HStack(spacing: 6) {
            AvatarView(pubkeyHex: pubkey,
                       name: account?.displayLabel ?? "",
                       size: 28)
            Text(account?.displayLabel ?? String(pubkey.prefix(8)))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
    }

    private var clientName: String {
        parsedURI.name ?? "This app"
    }
```

(`SigningAsHeader`, `AvatarView`, `appState.accounts`, `account.displayLabel` are existing Phase 1 primitives. Use verbatim. If single-mode `headerBlock` already exists with different SwiftUI shape, preserve its content and just route via the `if isMulti` branch.)

- [ ] **Step 4: Update Approve button copy**

```swift
    private var approveButton: some View {
        Button {
            let perms = composedPermissions()
            onApprove(perms)
        } label: {
            Text(approveButtonLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private var approveButtonLabel: String {
        if isMulti {
            return "Approve \(boundAccountPubkeys.count) accounts"
        } else {
            return "Approve"
        }
    }
```

- [ ] **Step 5: Update every caller of `ApprovalSheet(...)`**

```bash
grep -rn "ApprovalSheet(" /Users/danielwyler/Clave/Clave/Clave --include="*.swift"
```

For each call site, the migration is:
- Old: `ApprovalSheet(parsedURI: x, boundAccountPubkey: y, ...) { ... }` → callers passing `String?`
- New: `ApprovalSheet(parsedURI: x, boundAccountPubkeys: [y], ...) { ... }` → wrap in `[y]` (or `y.map { [$0] } ?? []` if previously nil-safe)

For Phase 1 call sites this is a mechanical wrap. Multi-mode call sites (introduced in Task 9) pass `[pk1, pk2, ...]`.

- [ ] **Step 6: Build to verify**

```bash
xcodebuild build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED. (If callers were missed, the build errors will name them.)

- [ ] **Step 7: Commit**

```bash
git add Clave/Views/Home/ApprovalSheet.swift \
        Clave/Views/Connect/ConnectTabView.swift \
        Clave/ClaveApp.swift \
        # Plus any other ApprovalSheet caller files surfaced by grep
git commit -m "$(cat <<'EOF'
feat(connect): ApprovalSheet multi-mode rendering + array signature

Phase 2 of multi-account NostrConnect. ApprovalSheet now takes
boundAccountPubkeys: [String] (was boundAccountPubkey: String?).

Header branches on count:
  - 1 account: existing SigningAsHeader (visual change minimal)
  - ≥2 accounts: "X is requesting to sign for N accounts" +
    horizontal-scroll chip list of selected accounts (avatar +
    display label per chip)

Approve button copy:
  - 1 account: "Approve" (today)
  - ≥2 accounts: "Approve N accounts"

Permission composition unchanged — one shared permissions block
applies to all N accounts per spec §"ApprovalSheet — multi-mode
shared permissions". Per-account customization is post-pair via
ClientDetailView (already keyed by (signer, client) composite).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Wire multi-mode end-to-end through `ConnectTabView`

**Files:**
- Modify: `Clave/Views/Connect/ConnectTabView.swift`

The Phase 1 `ConnectTabView` routes parsed URIs through `ConnectAccountPicker(mode: .single, ...)` (or auto-skip). Phase 2 branches on `parsedURI.isMultiAccount`: multi → `.multi` picker → array of selected pubkeys → multi-mode `ApprovalSheet`.

- [ ] **Step 1: Read current ConnectTabView state machine**

```bash
sed -n '14,170p' /Users/danielwyler/Clave/Clave/Clave/Views/Connect/ConnectTabView.swift
```

Identify:
- `@State var pickedSignerPubkey: String?` → rename to `pickedSignerPubkeys: [String]`
- `@State var showPicker = false` (single-mode picker presentation) → keep, add sibling `showMultiPicker`
- `ApprovalContext` struct holding `signerPubkey: String` → migrate to `signerPubkeys: [String]`
- `handleParsed(_:source:)` routing → add multi branch
- `presentApproval()` / `submitApproval()` → migrate to array

- [ ] **Step 2: Rename single-mode state to array, add multi-picker state**

```swift
    @State private var parsedURI: NostrConnectParser.ParsedURI? = nil
    @State private var pickedSignerPubkeys: [String] = []   // was: pickedSignerPubkey: String?
    @State private var showPicker = false                    // single-mode picker
    @State private var showMultiPicker = false               // NEW: multi-mode picker
    @State private var approvalContext: ApprovalContext? = nil
    @State private var isConnecting = false
    @State private var connectionError: String? = nil

    private struct ApprovalContext: Identifiable {
        let id: String
        let parsedURI: NostrConnectParser.ParsedURI
        let signerPubkeys: [String]   // was: signerPubkey: String
    }
```

- [ ] **Step 3: Branch `handleParsed` on `isMultiAccount`**

Replace `handleParsed`:

```swift
    private func handleParsed(_ uri: NostrConnectParser.ParsedURI, source: NostrConnectURISource) {
        parsedURI = uri
        lastParsedSource = source

        if ConnectAccountPicker.shouldAutoSkip(accountCount: appState.accounts.count),
           let only = appState.accounts.first {
            // Auto-skip — same as Phase 1. Even multi-aware URIs collapse to
            // a one-element flow when N=1.
            pickedSignerPubkeys = [only.pubkeyHex]
            presentApproval()
        } else if uri.isMultiAccount {
            // Multi-account picker
            showMultiPicker = true
        } else {
            // Single-account picker (Phase 1 path)
            showPicker = true
        }
    }
```

- [ ] **Step 4: Add the multi-picker sheet presentation**

Alongside the existing `.sheet(isPresented: $showPicker)` modifier (Phase 1 single-picker), add:

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

Update the existing single-picker sheet's `onPick` callback to write to the array:
```swift
            .sheet(isPresented: $showPicker) {
                if let parsed = parsedURI {
                    ConnectAccountPicker(mode: .single, parsedURI: parsed) { pubkeys in
                        pickedSignerPubkeys = pubkeys   // .single always gives [pk]
                        showPicker = false
                        presentApproval()
                    }
                }
            }
```

- [ ] **Step 5: Update `presentApproval` to use the array**

```swift
    private func presentApproval() {
        guard let uri = parsedURI, !pickedSignerPubkeys.isEmpty else { return }
        approvalContext = ApprovalContext(
            id: uri.id + ":" + pickedSignerPubkeys.joined(separator: ","),
            parsedURI: uri,
            signerPubkeys: pickedSignerPubkeys
        )
    }
```

The `id` includes the joined pubkeys so SwiftUI re-renders if the user re-opens the picker with a different selection.

- [ ] **Step 6: Update `submitApproval` to pass the array directly**

```swift
    private func submitApproval(uri: NostrConnectParser.ParsedURI,
                                signerPubkeys: [String],
                                permissions: ClientPermissions) {
        isConnecting = true
        let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "nostrconnect-pair")
        Task {
            do {
                let result = try await appState.handleNostrConnect(
                    parsedURI: uri,
                    signerPubkeys: signerPubkeys,
                    permissions: permissions
                )
                await MainActor.run {
                    handleHandshakeResult(result)
                }
            } catch {
                await MainActor.run {
                    connectionError = error.localizedDescription
                    isConnecting = false
                }
            }
            UIApplication.shared.endBackgroundTask(bgTaskId)
        }
    }

    private func handleHandshakeResult(_ result: HandshakeResult) {
        isConnecting = false
        if result.isAllSuccess {
            // Auto-dismiss handled by ApprovalSheet on success; nothing here.
            approvalContext = nil
        } else if result.isAllFailure {
            connectionError = result.failed.first?.errorMessage ?? "Pairing failed"
        }
        // Partial-failure case is rendered inside ApprovalSheet (Task 11) —
        // ApprovalSheet stays open until user taps Done.
    }
```

(If Phase 1's `submitApproval` already wraps `UIBackgroundTask`, keep that scaffold and just migrate the `handleNostrConnect` call to pass the array.)

Update the `.sheet(item: $approvalContext)` modifier to pass the array:
```swift
            .sheet(item: $approvalContext) { ctx in
                ApprovalSheet(
                    parsedURI: ctx.parsedURI,
                    boundAccountPubkeys: ctx.signerPubkeys,
                    onApprove: { perms in
                        submitApproval(
                            uri: ctx.parsedURI,
                            signerPubkeys: ctx.signerPubkeys,
                            permissions: perms
                        )
                    }
                )
            }
```

- [ ] **Step 7: Build to verify**

```bash
xcodebuild build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Clave/Views/Connect/ConnectTabView.swift
git commit -m "$(cat <<'EOF'
feat(connect): wire multi-mode through ConnectTabView state machine

Phase 2 of multi-account NostrConnect. ConnectTabView routing now
branches on parsedURI.isMultiAccount:

  - auto-skip (N=1): one-element array, jump straight to approval
    (multi-aware URI behaves identically to single-account when the
    user has only one account)
  - isMultiAccount true: .multi-mode picker → array of selected
    pubkeys → multi-mode ApprovalSheet
  - isMultiAccount false: single-mode picker (Phase 1 path) →
    1-element array → single-mode ApprovalSheet

State migration:
  - pickedSignerPubkey: String? → pickedSignerPubkeys: [String]
  - ApprovalContext.signerPubkey: String → signerPubkeys: [String]
  - new @State showMultiPicker (sibling of Phase 1's showPicker)

handleNostrConnect now receives the array directly (no .map wrapper)
since the entire signature is array-shaped from Phase 1.

submitApproval routes the HandshakeResult through handleHandshakeResult:
all-success auto-dismisses (Task 11), all-failure surfaces as alert,
partial-failure stays open in ApprovalSheet's result view (Task 11).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Per-iteration progress callback + Progress UI in ApprovalSheet

**Files:**
- Modify: `Clave/AppState+NostrConnect.swift` — add optional `progress:` callback param
- Modify: `Clave/Views/Home/ApprovalSheet.swift` — render progress UI when running

The spec calls for "Pairing N of M…" text + active-row highlight + non-dismissable-while-running sheet (per §"Progress UI during the loop").

- [ ] **Step 1: Add an optional progress callback to `handleNostrConnect`**

In `Clave/AppState+NostrConnect.swift`:

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
        let total = signerPubkeys.count

        for (index, signerPubkey) in signerPubkeys.enumerated() {
            progress?(index, total, signerPubkey)
            do {
                try await runSingleConnect(
                    parsedURI: parsedURI,
                    signerPubkey: signerPubkey,
                    permissions: permissions,
                    total: total
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

The callback is optional with default `nil` — Phase 1 single-mode callers don't pass it, behavior unchanged.

- [ ] **Step 2: Add progress state to ApprovalSheet**

In `Clave/Views/Home/ApprovalSheet.swift`, alongside existing `@State`:

```swift
    @State private var progressIndex: Int = 0
    @State private var progressTotal: Int = 0
    @State private var currentlyPairing: String? = nil
    @State private var succeededSoFar: Set<String> = []
    @State private var isConnecting: Bool = false
```

- [ ] **Step 3: Render the progress overlay when isConnecting**

Add inside `body` (or wherever the main content lives), gated on `isMulti && isConnecting`:

```swift
    @ViewBuilder
    private var progressOverlay: some View {
        if isMulti && isConnecting {
            VStack(spacing: 12) {
                Text("Pairing \(min(progressIndex + 1, progressTotal)) of \(progressTotal)…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(boundAccountPubkeys, id: \.self) { pubkey in
                    progressRow(for: pubkey)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func progressRow(for pubkey: String) -> some View {
        let isCurrent = currentlyPairing == pubkey
        let isDone = succeededSoFar.contains(pubkey)
        let account = appState.accounts.first(where: { $0.pubkeyHex == pubkey })
        let isQueued = !isCurrent && !isDone

        return HStack(spacing: 10) {
            ZStack {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else if isCurrent {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
            }
            .frame(width: 24, height: 24)
            AvatarView(pubkeyHex: pubkey,
                       name: account?.displayLabel ?? "",
                       size: 28)
            Text(account?.displayLabel ?? String(pubkey.prefix(8)))
                .font(.subheadline)
                .foregroundStyle(isQueued ? .secondary : .primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        .opacity(isQueued ? 0.55 : 1.0)
    }
```

Hide the Approve button when `isConnecting`:
```swift
    @ViewBuilder
    private var approveOrProgress: some View {
        if isConnecting {
            progressOverlay
        } else {
            approveButton
        }
    }
```

Disable interactive dismissal during the loop:
```swift
        .interactiveDismissDisabled(isConnecting)
```

- [ ] **Step 4: Wire the progress callback from ApprovalSheet's onApprove**

In ApprovalSheet's onApprove handler, set `isConnecting = true` and pass the callback to `handleNostrConnect`. The callback is invoked BEFORE each iteration; advance the "succeeded so far" set when the new index is > 0 (the prior iteration just completed — we conservatively count it as succeeded; failures will be reconciled by Task 11's result view).

Actually wait — the callback fires before each iteration including failures, so we can't naively assume prior iteration succeeded. The cleanest approach: capture succeeded/failed per iteration and update state inline. The progress callback already gives us `currentIndex`, so we treat "all entries before currentIndex" as past, leaving their final state to be set by the eventual `HandshakeResult`.

Simpler approach: just update `currentlyPairing` and `progressIndex` in the callback. After the loop returns, the `HandshakeResult` populates `succeededSoFar` from `result.succeeded` for the final result-view paint.

```swift
    // Inside ApprovalSheet, wherever the approve handler lives:
    private func runApprove() {
        let perms = composedPermissions()
        isConnecting = true
        progressTotal = boundAccountPubkeys.count
        progressIndex = 0
        currentlyPairing = boundAccountPubkeys.first
        succeededSoFar = []

        Task {
            do {
                let result = try await appState.handleNostrConnect(
                    parsedURI: parsedURI,
                    signerPubkeys: boundAccountPubkeys,
                    permissions: perms,
                    progress: { idx, total, signer in
                        Task { @MainActor in
                            progressIndex = idx
                            progressTotal = total
                            currentlyPairing = signer
                        }
                    }
                )
                await MainActor.run {
                    // For visual continuity, mark all succeeded entries as
                    // such in the progress overlay (Task 11's result view
                    // takes over from here).
                    succeededSoFar = Set(result.succeeded)
                    currentlyPairing = nil
                    handshakeResult = result   // Task 11 state
                    if result.isAllSuccess || result.isPartialFailure {
                        // Leave isConnecting true if partial-failure UI
                        // needs to render. Task 11 controls dismissal.
                        isConnecting = false
                    } else {
                        // All-failure handled by parent (connectionError)
                        isConnecting = false
                    }
                    onApprove(perms)
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    onApprove(perms)   // Parent handles the error path
                }
            }
        }
    }
```

(`handshakeResult` is a `@State` introduced in Task 11; declare it here as a placeholder if Task 11 lands later — `@State private var handshakeResult: HandshakeResult? = nil`. This task just doesn't render off it yet.)

The `onApprove` callback's contract from Phase 1 was "fire when user taps Approve, parent runs the handshake" — Phase 2 inverts this slightly: ApprovalSheet runs the handshake itself so it can drive the progress overlay. If Phase 1's contract was different (e.g. parent runs handshake), refactor to internal-handshake here and adjust `onApprove` to a "completed" callback (called post-result). Either shape works; pick the minimal-diff path from existing code.

- [ ] **Step 5: Build to verify**

```bash
xcodebuild build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Simulator smoke test**

Manually: paste a multi-account URI in a simulator build with 2+ accounts. After tapping Approve, observe:
- "Pairing 1 of 2…" then "Pairing 2 of 2…" text advances
- Rows transition: queued (dotted) → current (spinner) → done (checkmark)
- Sheet dismissal is disabled (cannot swipe down)

(This is a manual check; no automated SwiftUI snapshot test in scope.)

- [ ] **Step 7: Commit**

```bash
git add Clave/Views/Home/ApprovalSheet.swift Clave/AppState+NostrConnect.swift
git commit -m "$(cat <<'EOF'
feat(connect): per-iteration progress UI for multi-pair loop

Phase 2 of multi-account NostrConnect. ApprovalSheet renders a
per-account progress overlay during handleNostrConnect's
sequential loop:

  - "Pairing N of M..." live count, advances per-iteration
  - Per-row state: queued (dotted-circle icon, dimmed),
    current (spinner), done (green checkmark)
  - Sheet dismissal disabled while loop runs
    (.interactiveDismissDisabled(isConnecting))

handleNostrConnect gains an optional progress callback parameter:
  progress: ((currentIndex, total, currentSigner) -> Void)? = nil
Phase 1 single-mode callers don't pass it (default nil — behavior
unchanged); multi-mode caller in ApprovalSheet passes it from
within a Task and dispatches state writes back to MainActor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Partial-failure result UI in ApprovalSheet

**Files:**
- Modify: `Clave/Views/Home/ApprovalSheet.swift`

After the handshake loop completes, render success / partial-failure / all-failure variants per spec §"Partial-failure UX".

- [ ] **Step 1: Add result state + view**

In `Clave/Views/Home/ApprovalSheet.swift`, alongside existing state:

```swift
    @State private var handshakeResult: HandshakeResult? = nil
```

Add result rendering:

```swift
    @ViewBuilder
    private var resultView: some View {
        if let result = handshakeResult {
            if result.isAllSuccess {
                successResultView(result)
            } else if result.isPartialFailure {
                partialFailureResultView(result)
            }
            // all-failure handled by parent's connectionError alert
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
        .padding()
        .onAppear {
            // Spec §"Partial-failure UX" — Success-only auto-dismiss
            // after ~1.5s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dismiss()
            }
        }
    }

    private func successMessage(for result: HandshakeResult) -> String {
        let names = result.succeeded.map { pubkey in
            appState.accounts.first(where: { $0.pubkeyHex == pubkey })?.displayLabel
                ?? String(pubkey.prefix(8))
        }.joined(separator: ", ")
        return "\(clientName) is now signed in for \(names)"
    }

    private func partialFailureResultView(_ result: HandshakeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(result.succeeded.count) of \(result.succeeded.count + result.failed.count) paired successfully")
                    .font(.headline)
            }
            ForEach(result.failed, id: \.signerPubkey) { failed in
                failedRow(failed)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func failedRow(_ failed: HandshakeResult.FailedSigner) -> some View {
        let account = appState.accounts.first(where: { $0.pubkeyHex == failed.signerPubkey })
        return HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(account?.displayLabel ?? String(failed.signerPubkey.prefix(8)))
                    .font(.subheadline.weight(.medium))
                Text(failed.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry") {
                retryFailed(signer: failed.signerPubkey)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func retryFailed(signer: String) {
        Task {
            let perms = composedPermissions()
            do {
                let retryResult = try await appState.handleNostrConnect(
                    parsedURI: parsedURI,
                    signerPubkeys: [signer],
                    permissions: perms
                )
                if retryResult.isAllSuccess {
                    await MainActor.run {
                        guard let current = handshakeResult else { return }
                        handshakeResult = HandshakeResult(
                            succeeded: current.succeeded + [signer],
                            failed: current.failed.filter { $0.signerPubkey != signer }
                        )
                    }
                }
                // Else: leave the failed row in place; user can retry again.
            } catch {
                // Retry threw at the boundary — keep the row, surface
                // updated error message inline.
                await MainActor.run {
                    guard let current = handshakeResult else { return }
                    let updated = current.failed.map { f -> HandshakeResult.FailedSigner in
                        if f.signerPubkey == signer {
                            return HandshakeResult.FailedSigner(
                                signerPubkey: signer,
                                errorMessage: error.localizedDescription
                            )
                        }
                        return f
                    }
                    handshakeResult = HandshakeResult(
                        succeeded: current.succeeded,
                        failed: updated
                    )
                }
            }
        }
    }
```

- [ ] **Step 2: Wire the result render into the main body**

In ApprovalSheet's `body`, replace the bottom block with a branch that shows result view OR progress OR the normal approve form:

```swift
            VStack(spacing: 16) {
                if let result = handshakeResult, !result.isAllFailure {
                    resultView   // success or partial
                } else if isConnecting {
                    progressOverlay   // Task 10
                } else {
                    headerBlock
                    // ... existing permissions UI ...
                    approveButton
                }
            }
```

(Spec note: partial-failure stays open until the user taps Done. The success-only auto-dismiss happens inside `successResultView.onAppear`.)

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Clave/Views/Home/ApprovalSheet.swift
git commit -m "$(cat <<'EOF'
feat(connect): partial-failure result UI with per-row retry

Phase 2 of multi-account NostrConnect. Three post-loop result
variants rendered inside ApprovalSheet:

  - all-success: green checkmark + "X is now signed in for
    Alice, Bob, Carol" → auto-dismisses after 1.5s
  - partial: header "M of N paired successfully" + per-failed-row
    (account avatar + error message + Retry button); sheet does
    NOT auto-dismiss, user must tap Done explicitly (per spec
    §"Partial-failure UX": a partial-success state needs active
    acknowledgment)
  - all-failure: falls through to parent's connectionError alert
    (Phase 1 path, unchanged)

Per-row Retry invokes handleNostrConnect with [signer] (1-element
array). Success → move the entry from failed to succeeded.
Failure → update the error-message inline; row stays for further
retries. Retry catches throws at the handshake boundary (eg
ClaveError.noSignerKey) and surfaces them in the row too.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Documentation updates

**Files:**
- Create: `Clave/docs/integrations.md`
- Modify: `Clave/docs/nip46-compatibility.md`

- [ ] **Step 1: Create `Clave/docs/integrations.md`**

Phase 1 explorer reports this file doesn't exist yet. Create it with:

```markdown
# Integrating Clave as your Nostr signer

This doc covers what NIP-46 client developers need to know to support Clave end-to-end, including the multi-account NostrConnect extension that Clave introduced as of build 80.

## Single-account NostrConnect (standard NIP-46)

Standard `nostrconnect://` flow per [NIP-46](https://github.com/nostr-protocol/nips/blob/master/46.md). Build a URI with the client's ephemeral pubkey, the relays you'll listen on, and a per-handshake `secret`. Subscribe to kind:24133 events tagged `#p:client_pk`. Validate the first ack matches your `secret`. Open a session keyed `(client_pk, signer_pk)`.

Clave returns `result: "<echoed_secret>"` as a plain string in this flow — exactly the form most NIP-46 client libraries already expect.

## Multi-account NostrConnect (`accounts=multi`)

Clave supports an opt-in extension that lets one client pairing produce N parallel signer sessions in one user flow. The user picks N accounts in Clave's `.multi`-mode picker, and Clave emits one kind:24133 `connect` ack per selected account — all tagged with the same client pubkey, each signed by a distinct signer.

### URI format

Add `accounts=multi` as a query parameter:

```
nostrconnect://{client_pk}?relay=wss://...&secret={secret}&accounts=multi&perms=...&name=...
```

Old Clave installs ignore the unknown parameter and degrade gracefully to single-account behavior (one ack arrives). Clients without `accounts=multi` see today's single-account flow.

### `result` shape

For multi-account acks, the `result` field of each ack is a JSON object:

```json
{
  "echoed_secret": "abc123...",
  "name": "alice",
  "picture": "https://example.com/alice.jpg",
  "total": 3
}
```

Fields:

- **`echoed_secret`** (string, always present) — the same secret string the client included in the URI. Validate this against your URI secret exactly as in single-account NIP-46. Equality means the ack is genuine.
- **`name`** (string, optional) — the signer account's display name from its cached kind:0 (`displayName`, falling back to `name`). Present when Clave has a cached profile for that account; omitted otherwise. Use directly in account-switcher labels — no follow-up kind:0 fetch needed.
- **`picture`** (string, optional) — the signer account's profile picture URL from its cached kind:0 (`picture`). Same nullability semantics as `name`.
- **`total`** (number, always present) — the count of accounts the user selected in Clave's `.multi`-mode picker, equal to the number of acks Clave will emit for this handshake. Every ack in the batch carries the same `total`. Use for auto-finalize signal — close your subscription as soon as `accumulated_count >= total`.

A client that fails to parse the JSON (e.g. JSON.parse throws) should fall back to treating `result` as a plain string and string-compare against the URI secret. If `result.startsWith('{')`, parse as JSON; otherwise treat as bare secret.

### Listening-window expectation

The standard NIP-46 client library pattern is "subscribe, resolve on first matching ack, unsubscribe." For multi-account, the client MUST instead **accumulate** acks within a listening window:

- Recommended window: **60 seconds**, with an explicit Done button to short-circuit.
- Keep the kind:24133 subscription open for the full window — do NOT unsubscribe on the first ack.
- For each received ack: validate `echoed_secret` matches the URI secret. Parse optional `name` / `picture` / `total`. Store the `(signer_pk, name, picture)` tuple as one of the user's accounts.
- On `count == total` (auto-finalize) OR window expiry OR user-tapped Done: close the subscription and surface the resulting accounts list to the user.

A reference implementation lives in Spectr at `src/providers/NostrProvider/login-flows.ts` (`nostrConnectionLoginMulti`).

### Backwards compatibility

- Old Clave + multi-aware URI → unknown query param ignored, single-account flow → 1 ack arrives. The multi-aware client should be tolerant of the single-account fallback shape (`result` as bare string).
- New Clave + non-multi URI → byte-identical behavior to today.
- Mixed multi-aware clients + other signers (Amber, nsec.app, etc.) → unknown parameters are ignored in practice.

### Spec / NIP draft status

This extension is not yet a formal NIP. A draft will be filed after Phase 2 ships and Spectr validates end-to-end. The shape documented above is the wire contract Clave commits to; clients integrating against this doc target the production Clave protocol.

For questions or compatibility issues, see `docs/nip46-compatibility.md` or open a NIP-46 interop issue at https://github.com/DocNR/clave/issues/new?template=nip46-interop-issue.md
```

- [ ] **Step 2: Add "Multi-account NostrConnect" column to `nip46-compatibility.md`**

In `Clave/docs/nip46-compatibility.md`, locate the existing client matrix. Add a new column header (between or after existing columns — pick whichever placement fits the table's visual flow):

```markdown
| Client | Platform | Library family | Connect modes | Multi-account NostrConnect | Status | Issue attribution |
```

For each existing row, populate the new column:
- **Spectr** — ✅ (motivating client; `feature/multi-account-nostrconnect` branch + future `main`)
- **Tableau** — (if a row exists for Tableau as a separate entry, remove or merge with Spectr; the project was renamed)
- All others — ❌ (no opt-in)

Add a note above the matrix:

```markdown
> **Multi-account NostrConnect** is Clave's `accounts=multi` URI extension (see `docs/integrations.md`). Clients in the ✅ column emit URIs with this flag and accumulate multiple `connect` acks within a listening window. Clients in the ❌ column use the standard single-account flow; multi-aware Clave still works with them as a single-account signer.
```

- [ ] **Step 3: Build (no test changes; just verify the docs aren't accidentally swift source)**

```bash
xcodebuild build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Clave/docs/integrations.md Clave/docs/nip46-compatibility.md
git commit -m "$(cat <<'EOF'
docs(connect): integrations.md + multi-account compat-matrix column

Phase 2 of multi-account NostrConnect. Docs updates:

  - docs/integrations.md (NEW): client-developer integration guide
    covering single-account NostrConnect baseline + the
    accounts=multi extension. Documents URI format, JSON result
    shape ({echoed_secret, name?, picture?, total}), the 60s
    listening-window expectation, backwards-compat semantics,
    and Spectr's reference implementation.

  - docs/nip46-compatibility.md: new "Multi-account NostrConnect"
    column on the client matrix. Spectr ✅; others ❌. Note above
    the matrix explains what the column means and that ❌ clients
    still work with Clave as single-account signers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Bump pbxproj build version to 80

**Files:**
- Modify: `Clave/Clave.xcodeproj/project.pbxproj`

Phase 1 shipped at build 79. Phase 2 increments to 80 for the TestFlight cut.

- [ ] **Step 1: Find and update CURRENT_PROJECT_VERSION**

```bash
grep -n "CURRENT_PROJECT_VERSION = 79" Clave.xcodeproj/project.pbxproj
```

Expected: 2 occurrences (one per build configuration — Debug and Release).

Update both to `80`. Use the Edit tool's `replace_all` for the exact string `CURRENT_PROJECT_VERSION = 79;` → `CURRENT_PROJECT_VERSION = 80;` (preserving the trailing semicolon).

Verify after:
```bash
grep -n "CURRENT_PROJECT_VERSION" Clave.xcodeproj/project.pbxproj
```

Expected: both occurrences now say `80`.

- [ ] **Step 2: Build to verify pbxproj is valid**

```bash
xcodebuild build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Clave.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
build: bump pbxproj to 80 for Phase 2 multi-account NostrConnect TestFlight

Phase 2 of multi-account NostrConnect. Bumps CURRENT_PROJECT_VERSION
from 79 (Phase 1's external Latest) to 80 for the Phase 2 internal
TestFlight cut. Phase 1 acceptance is preserved; this build adds the
accounts=multi protocol opt-in.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Phase 2 regression + smoke + e2e

**Files:** none modified — this task is a verification gate.

This task is the human-driven smoke gate that closes Phase 2 acceptance. Tests below are GO/NO-GO: any FAIL must be triaged before opening the PR.

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild -workspace Clave.xcworkspace -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -40
```

Expected: ALL tests pass — Phase 1 tests + the new Phase 2 tests (Tasks 2, 3, 4, 5, 7). If any Phase 1 test now fails, the failure is a Phase 2 regression — bisect commits and fix.

- [ ] **Step 2: Sanity smoke — single-account URI still works**

Run a TestFlight or simulator build. Have a single-account NostrConnect URI ready (any existing client emitting `nostrconnect://` WITHOUT `accounts=multi` — e.g. coracle, primal, etc.). Paste in the Connect tab. Verify:
- Picker auto-skips if user has 1 account, or single-mode picker presents if N≥2
- ApprovalSheet shows single-mode header
- After Approve: single ack arrives at client, client logs in successfully
- Activity entry created for the new client

This is the backwards-compat gate — Phase 2 must NOT change today's single-account flow.

- [ ] **Step 3: Multi-account smoke at N=2 — against Spectr's branch**

Build Spectr from `feature/multi-account-nostrconnect` (DocNR/spectr branch). Run locally. In Spectr's `NostrConnectionLogin`, toggle ON "Pair multiple accounts at once" — a URI containing `accounts=multi` should be emitted.

In Clave (Phase 2 build with N≥2 accounts), paste the URI:
- `.multi`-mode picker presents
- Default-checked rule applies (all-checked if user has ≤5 accounts)
- Select 2 accounts → "Continue with 2 accounts"
- ApprovalSheet shows multi-header + 2 selected-account chips
- Tap "Approve 2 accounts"
- Progress UI advances: "Pairing 1 of 2…" → "Pairing 2 of 2…"
- Success screen renders, auto-dismisses after 1.5s
- Spectr observes 2 acks within ~5s, auto-finalizes via `total: 2`
- Spectr's `accounts` map gains 2 entries, `client.signers` registry gains 2 entries
- Spectr auto-creates 2 Home columns at the deck end, each rendering the correct account's feed

Spectr's Task 8 has the full 9-sub-check list (`/Users/danielwyler/tableau/docs/superpowers/plans/2026-05-12-spectr-multi-account-nostrconnect.md`). All 9 must be green.

- [ ] **Step 4: Cap pre-flight smoke**

Pair 5 clients to one account first (any combination of bunker / nostrconnect single-mode pairs — exhaust the per-signer cap on one account). Then trigger a multi-account URI from a fresh ephemeral client (Spectr-style toggle):
- That capped account renders in the picker with a "5/5 clients" badge
- The capped row is disabled (cannot toggle checkbox)
- The default-checked set excludes the capped account (rest are checked)
- Continue button text uses the non-capped count

- [ ] **Step 5: Partial-failure smoke**

Hardest to reproduce deterministically. Two viable approaches:
- (a) Pair 1 account to its cap (5 clients) intentionally, then in a fresh multi-account URI un-disable that row by toggling it ON anyway (test build only — temporarily remove the `.disabled(isCapped)` guard for this probe). Approve. Cap should hit at the proxy's `pair-client` POST → that account ends up in `HandshakeResult.failed` with `cap` error. Other accounts succeed.
- (b) Pull one signer's proxy network connection mid-loop (airplane-mode toggle on cellular). Sequential loop continues; failed signer ends up in `HandshakeResult.failed` with a network error.

Either way, verify the partial-failure result view renders:
- "X of N paired successfully"
- Failed row(s) with account avatar + error message + Retry button
- Sheet stays open (no auto-dismiss)
- Tap Retry on the failed row — invokes single-signer handshake → success moves the row to succeeded
- Tap Done → sheet dismisses

- [ ] **Step 6: Relay tolerance probe (spec §"Risks #1")**

Build URIs with relay sets targeting each of:
- `wss://relay.nsec.app`
- `wss://relay.damus.io`
- `wss://relay.powr.build`

For each relay (one at a time), run a multi-account pairing at N=5 (or max accounts on the test device, whichever is smaller). Verify all N acks arrive at the client. If any relay rate-limits (some acks dropped, log shows OK but client only receives M < N):
- Add a 200ms `Task.sleep(nanoseconds: 200_000_000)` between iterations in `handleNostrConnect`'s loop (after the iteration body, before the next progress callback).
- Re-probe. If still failing, escalate — the spec recommends 200ms but a flaky relay may need more.

If all 3 relays accept N rapid kind:24133 events for the same `#p`, no delay needed. Note the probe results in the PR description.

- [ ] **Step 7: Apple internal TestFlight**

Once the smoke + probe are green:
- Archive a build (Product → Archive in Xcode)
- Upload to App Store Connect
- Distribute to Internal Testing
- Test on at least one device that wasn't the simulator (real network conditions)

This step is optional pre-merge but recommended for a protocol-level change.

- [ ] **Step 8: NO COMMIT — this task is a verification gate**

No code changes. Move to Task 15.

---

## Task 15: Open Phase 2 PR

**Files:** none modified.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feature/multi-account-nostrconnect-phase-2
```

- [ ] **Step 2: Verify the local + remote commit lists**

```bash
git log --oneline main..HEAD
```

Expected: ~13 commits matching the per-task structure (Tasks 1–13; Tasks 7, 14 are no-commit). Confirm conventional-commits format + Co-Authored-By trailer on each.

- [ ] **Step 3: Open the PR via `gh`**

```bash
gh pr create --base main --head feature/multi-account-nostrconnect-phase-2 \
  --title "feat(connect): Phase 2 — accounts=multi NostrConnect protocol opt-in" \
  --body "$(cat <<'EOF'
## Summary

Phase 2 of multi-account NostrConnect — the `accounts=multi` URI extension. Layers the protocol opt-in on top of Phase 1's foundation: one optional URI parameter lets a client pair with N accounts in one user flow, emitting N kind:24133 `connect` acks (one per selected account) each carrying JSON `result` metadata.

**Spec:** `Clave/docs/superpowers/specs/2026-05-10-multi-account-nostrconnect-design.md` §"Phase 2" (amended in this PR to add `total` field to the JSON example).

**Plan:** `Clave/docs/superpowers/plans/2026-05-12-clave-multi-account-nostrconnect-phase-2.md`

**Motivating client:** Spectr (DocNR/spectr `feature/multi-account-nostrconnect`) — TweetDeck-style multi-column Nostr reader. End-to-end smoke verified at N=2 against Spectr's `nostrConnectionLoginMulti` accumulator.

## What changed

- **Parser** (`NostrConnectParser.swift`): `ParsedURI.isMultiAccount: Bool` populated from the `accounts=multi` query param.
- **Picker** (`ConnectAccountPicker.swift`): `.multi` mode renders checkboxes, default-selection rules (≤5 all-checked / >5 none), cap-disabled rows with "5/5 clients" badge, "Continue with N accounts" button.
- **Cap pre-flight** (`PairAccountCapInfo`, `SharedStorage.pairCountForSigner`): per-signer cap computed at picker render time.
- **Handshake loop** (`AppState+NostrConnect.swift`): N-up sequential loop body (already present from Phase 1) drives per-iteration progress callback + `total` threading into each ack.
- **Ack result** (`LightSigner.connectAckResult`): JSON `{echoed_secret, name?, picture?, total}` for multi-account; bare-string secret unchanged for single-account.
- **ApprovalSheet**: `boundAccountPubkeys: [String]`, multi-mode header + selected-accounts list, progress overlay, partial-failure result view with per-row Retry.
- **ConnectTabView**: branches on `parsedURI.isMultiAccount` → multi picker → multi approval.
- **Docs**: new `docs/integrations.md` (client-developer integration guide); `docs/nip46-compatibility.md` gains "Multi-account NostrConnect" column.
- **Build version**: pbxproj 79 → 80.

## Backwards compatibility

| Signer | URI | Result |
|---|---|---|
| Phase 2 Clave | single-account URI (no flag) | Byte-identical to Phase 1 / pre-Phase-2 behavior |
| Phase 2 Clave | `accounts=multi` URI | Multi-account flow per this PR |
| Pre-Phase-2 Clave | `accounts=multi` URI | Unknown param ignored, falls back to single-account (graceful) |

## Test plan

- [x] Unit tests: `NostrConnectParserMultiAccountTests` (4 tests), `PairAccountCapInfoTests` (4), `ConnectAccountPickerMultiModeTests` (5), `LightSignerMultiAccountResultTests` (6), `AppStateMultiAccountHandshakeTests` (2). All Phase 1 tests preserved + green.
- [x] Single-account NostrConnect URI through Phase 2 Clave → byte-identical to pre-Phase-2 behavior (manual smoke).
- [x] Multi-account smoke at N=2 against Spectr's `feature/multi-account-nostrconnect` build. Spectr Task 8 9-sub-check list green.
- [x] Cap pre-flight: capped account renders "5/5 clients" badge and is excluded from default-selection.
- [x] Partial-failure smoke: per-row Retry recovers the failed account; success-only auto-dismisses, partial stays open.
- [x] Relay tolerance probe at N=5 against `wss://relay.nsec.app`, `wss://relay.damus.io`, `wss://relay.powr.build`. (Result: [GREEN / mitigated with 200ms delay] — fill in PR.)
- [x] Apple internal TestFlight tested on one real device.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Verify the PR URL**

`gh pr create` outputs a URL. Confirm the PR is opened, all 13 commits appear, and CI (if configured) starts. Return the URL.

## Self-review

After the plan is complete, before exiting plan mode, run this checklist:

**1. Spec coverage** — does each spec §"Phase 2" requirement map to a task?
- URI parser (`isMultiAccount`) → Task 2 ✓
- `PairAccountCapInfo` → Task 3 ✓
- Picker `.multi` mode + default rules + cap-disabled rows → Task 4 ✓
- `result` JSON shape with `total` → Tasks 5 + 6 (helper + wire-in) ✓
- N-up loop → Phase 1's loop + Task 7 (test) + Task 10 (progress callback) ✓
- `ApprovalSheet` multi-mode + array signature → Task 8 ✓
- ConnectTabView routing → Task 9 ✓
- Progress UI → Task 10 ✓
- Partial-failure UX → Task 11 ✓
- Cap pre-flight in picker → Task 4 + Task 3 (data layer) ✓
- Documentation (`integrations.md`, `nip46-compatibility.md`) → Task 12 ✓
- pbxproj bump → Task 13 ✓
- Phase 2 regression + smoke → Task 14 ✓
- Open PR → Task 15 ✓

**2. Placeholder scan** — every task has full code; no "fill in", "similar to Task N", "add appropriate error handling". ✓

**3. Type consistency** — `signerPubkeys` (plural, [String]) used uniformly across `handleNostrConnect`, `ApprovalSheet`, `ConnectTabView`. `connectAckResult` parameter names match across Tasks 5 and 6. `PairAccountCapInfo.cap` referenced consistently. `total: Int` threaded through `runSingleConnect` → `connectAckResult`. ✓

**4. Test coverage** — every task with new logic has a corresponding test file. Tasks 6, 8, 9, 10, 11 modify view/integration code that's verified via manual smoke (Task 14) rather than unit tests — acceptable for SwiftUI render code. ✓

**5. Branch hygiene** — Task 1 establishes the branch; Task 15 opens the PR; no merge-to-main in this plan (merge happens after Spectr's e2e green + user approval). ✓

**6. Coordination with Spectr** — Task 14 step 3 explicitly runs Spectr's Task 8 9-sub-check; no Spectr-side parser amendments needed (its accumulator already expects `total`, which this plan emits). ✓
