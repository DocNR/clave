# Clave

**iOS NIP-46 remote signer. Your Nostr private key stays in the iPhone Keychain — clients sign events via encrypted push, without the app being open.**

[![TestFlight](https://img.shields.io/badge/iOS-TestFlight_beta-blue)](https://testflight.apple.com/) [![Platform](https://img.shields.io/badge/platform-iOS_17.6+-lightgrey)]()

## What it solves

Every Nostr app you use needs to sign events as you. The usual options are both bad:

- **Paste your nsec into every client.** Now N apps know your key. One compromise and your identity is gone — Nostr keys can't be rotated like passwords.
- **Use a web extension or hosted signer.** Only works when that tab/server is up. Doesn't help on mobile. Hosted signers mean someone else holds your key.

Clave is a third option. Your nsec lives in the iOS Keychain, never leaves the device. When a client wants to sign an event, it sends an encrypted request over Nostr, a push notification wakes Clave's background extension for ~30 seconds, and the extension decrypts, checks your permission rules, signs, and publishes the response. You control which clients can sign which event kinds.

Similar in spirit to [Amber on Android](https://github.com/greenart7c3/Amber) — but getting the same architecture working on iOS is harder, because iOS aggressively suspends background apps. Clave works around that via a small server-side push proxy + iOS Notification Service Extension.

## Status

**Beta.** In TestFlight internal, external review pending. Not yet recommended for your main nsec — use a throwaway key while we finish external testing. Full pre-external-TestFlight security audit completed 2026-04-17 with 5 must-fix items resolved in build 9 ([audit report](../hq/clave/security-audits/)).

What works end-to-end:

- **`bunker://` pairing flow** — Clave generates a URI, you paste it into a client, first-use secret establishes the pairing
- **`nostrconnect://` pairing flow** — client generates a URI, you paste it into Clave, approval sheet sets trust level + per-kind permissions
- **Per-client permissions** — Full / Medium / Low trust levels, plus per-kind overrides; protected kinds (0, 3, 5, 10002, 30078) prompt for approval on Medium trust by default
- **NIP-46 methods:** `connect`, `sign_event`, `get_public_key`, `ping`, `describe`, `switch_relays`, `nip04_encrypt`, `nip04_decrypt`, `nip44_encrypt`, `nip44_decrypt`
- **Activity log** — every sign + connect event logged, bounded to 200 entries, no plaintext / keys stored
- **Client detail view** — rename, change trust, view activity, unpair
- **Silent push suppression** — successful signs don't pop a notification; only pending approvals and errors do
- **Verified with:** Nostur, noStrudel, zap.cooking

Known limitations:

- **One relay** (`wss://relay.powr.build`) — multi-relay publishing is backlogged
- **noStrudel async approval** can time out on protected kinds (client-side timeout, not ours; workaround: Full Trust)
- **Debug builds can't test signing end-to-end** because sandbox APNs tokens can't reach the production proxy; only the nostrconnect handshake works locally in debug

## How it works

```
 Client app (Nostur / noStrudel / etc.)
    │
    │  publishes kind:24133 signing request, NIP-44 encrypted to signer pubkey
    ▼
 Nostr relay  (wss://relay.powr.build)
    │
    │  proxy subscribes to kind:24133
    ▼
 relay-proxy.service  (Node.js, signs APNs JWT, routes by p-tag)
    │
    │  Apple Push Notification (HTTP/2, ES256 JWT from .p8 key)
    ▼
 iPhone — Clave Notification Service Extension wakes for ~30s
    │
    │  reads nsec from Keychain (ThisDeviceOnly)
    │  decrypts request (NIP-44 v2)
    │  enforces per-client permission rules
    │  Schnorr-signs the inner event (BIP-340)
    │  publishes response to relay (NIP-44 encrypted to client)
    ▼
 Nostr relay
    ▼
 Client app  receives signed response, publishes it to the network
```

The magic is step 3–4: the proxy never sees the private key or the decrypted content. The push payload is just `{relay_url, event_id}` — content-free. The NSE is the only component that can sign, and it runs only in response to a push, for at most 30 seconds.

**Registration is authenticated via NIP-98.** When the iOS app registers its APNs device token with the proxy, it signs a kind:27235 event proving ownership of the pubkey. The proxy verifies the signature, timestamp (±60s), URL, method, and body hash before associating the token with a pubkey. An attacker without the nsec cannot bind their own APNs token to someone else's pubkey.

## Security model

**What never leaves the device:**
- The nsec (iOS Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not iCloud-synced, not included in device backups)
- Decrypted NIP-46 request contents (held in process memory only during the 30-second NSE window)
- Pre-publication event signatures (held only until published to the relay)

**What the push proxy sees:**
- APNs device tokens paired with pubkeys (via NIP-98-authenticated registration)
- That a kind:24133 event arrived for a registered pubkey (content is encrypted end-to-end; proxy can't decrypt)
- HTTP/2 response codes from APNs

**What the push proxy cannot do:**
- Sign events as any user (doesn't have any nsec)
- Read the contents of any signing request
- Bind a token to a pubkey it doesn't control (NIP-98 gate)
- Impersonate a signer to a client

**Pairing requires an explicit bond:**
- **bunker://** — a single-use secret in the URI that the client must echo on its first `connect` request; rotates after successful pairing
- **nostrconnect://** — the client's public key is saved as a paired client only after the user explicitly approves an approval sheet with trust settings

Unpaired clients are rejected for all methods. There is no "auto-sign for any caller" mode.

**Audit.** The codebase underwent a pre-external-TestFlight security audit on 2026-04-17: NIP-44 v2 primitives, Schnorr, NIP-98, permission dispatch, proxy-side verification, supply-chain + build integrity, operational security on the Dell host. Audit report is tracked in the `hq` companion repo under `security-audits/`. A weekly triage routine watches for drift on security-sensitive files; a full re-audit runs quarterly.

## Repository layout

| Path | Purpose |
|---|---|
| `Clave/` | SwiftUI app. Onboarding, key import/generate/delete/export, settings, connect UI, approval sheets, activity log, client detail |
| `Clave/ClaveApp.swift` | App entrypoint + APNs delegate + foreground push handler |
| `Clave/AppState.swift` | Observable app-level state, key lifecycle, proxy register/unregister, nostrconnect handshake |
| `ClaveNSE/` | Notification Service Extension. Wakes on push, decrypts request, signs, publishes response |
| `Shared/` | Code shared between main app and NSE (see below) |
| `relay-proxy/` | Node.js push proxy. Subscribes to relay, dispatches APNs pushes, authenticates registration via NIP-98 |
| `ClaveTests/` | Unit tests for NIP-98 signing, nostrconnect URI parsing, peekMethod helper |

### The `Shared/` crypto stack

The NSE has a tight budget (~24 MB RAM, 30 s wall-clock). The obvious choice — rust-nostr-swift — compiles to a binary that's too heavy. So the signing path uses a lightweight stack built on CryptoKit (Apple's built-in framework) + `swift-secp256k1` (a thin Swift wrapper around Bitcoin Core's `libsecp256k1`):

| File | Responsibility |
|---|---|
| `SharedKeychain.swift` | Reads/writes the nsec to the shared Keychain access group `dev.nostr.clave.shared` (accessible to both main app and NSE) |
| `Bech32.swift` | Decodes `nsec1...` bech32 strings to raw 32-byte private keys |
| `LightCrypto.swift` | Hand-written NIP-44 v2 (ECDH + HKDF + ChaCha20 + HMAC-SHA256 + padding) and NIP-04 (legacy AES-CBC) |
| `LightEvent.swift` | Nostr event serialization, SHA-256 id computation, BIP-340 Schnorr signing via swift-secp256k1, NIP-98 helper for HTTP auth headers |
| `LightSigner.swift` | NIP-46 request handler: decrypt → parse JSON-RPC → enforce per-client permissions → dispatch to `sign_event` / `nip*_encrypt` / `nip*_decrypt` / `get_public_key` / etc. → encrypt response → publish |
| `LightRelay.swift` | Foundation-only WebSocket client (`URLSessionWebSocketTask`); connect, REQ, EVENT, OK, disconnect |
| `ClientPermissions.swift` | Trust levels (Full/Medium/Low), per-kind overrides, method allowlist, known-kind labels |
| `NostrConnectParser.swift` | Parses `nostrconnect://` URIs into a validated struct |
| `SharedStorage.swift` | Activity log, pending approvals, connected clients, bunker secret rotation (all in shared UserDefaults / App Group) |
| `SharedConstants.swift` | App group id, Keychain service name, default relay URL, default proxy URL |
| `SharedModels.swift` | `ActivityEntry`, `PendingRequest`, `ConnectedClient` codable types |

### Why four hand-written crypto files?

- **`CryptoKit`** gives us SHA-256, HMAC-SHA256, HKDF scaffolding, and symmetric cipher building blocks — but it doesn't support the `secp256k1` curve (Apple chose `P-256` instead). So for Schnorr and NIP-44's ECDH we need…
- **`swift-secp256k1`** — a small (~500 KB) Swift wrapper around Bitcoin Core's `libsecp256k1`. Gives us secp256k1 ECDH + BIP-340 Schnorr. The combination fits under the NSE memory budget; a full nostr SDK does not.
- **`LightCrypto` + `LightEvent`** are thin application-level code built on top: wire the primitives together to match the NIP-44 v2, NIP-04, NIP-01, and BIP-340 specs exactly.

## Developer setup

### Prerequisites

- Xcode 16.2+ (for iOS 26.4 SDK; the NSE target deploys to 26.4)
- macOS with a recent enough iOS Simulator runtime, or a physical iPhone (recommended — NSE push delivery only works on real devices)
- Apple Developer account with push-notification capability
- Node.js ≥20.19 (for `@noble/curves@2.2` engine requirements in the proxy)
- A Nostr relay that accepts kind:24133 ephemeral events reliably. We use [strfry](https://github.com/hoytech/strfry) for `relay.powr.build`.

### Build the iOS app

```bash
git clone https://github.com/DocNR/clave.git
cd clave
open Clave.xcodeproj
```

In Xcode:

1. Select both the `Clave` and `ClaveNSE` targets. Under **Signing & Capabilities**, set your Team ID.
2. Verify both targets share:
   - App Groups: `group.dev.nostr.clave`
   - Keychain Sharing: `dev.nostr.clave.shared`
3. Verify the `Clave` target has:
   - Push Notifications capability
   - Background Modes → Remote notifications
4. `Package.resolved` pins `nostr-sdk-swift` 0.44.2 and `swift-secp256k1` 0.23.0. Both should resolve on first build.
5. Build and run on a physical device. Allow notifications when prompted. Generate or import a key.

### Run the proxy

On a box reachable via HTTPS (Cloudflare Tunnel works well; systemd unit example in `/etc/systemd/system/clave-proxy.service`):

```bash
cd relay-proxy
npm install
```

Create `.env`:

```
PORT=3046
APNS_KEY_ID=<your-key-id>
APNS_TEAM_ID=<your-team-id>
APNS_KEY_PATH=./AuthKey_<key-id>.p8
APNS_HOST=api.push.apple.com       # production
BUNDLE_ID=dev.nostr.Clave           # must match the iOS bundle id
RELAY_URL=ws://localhost:7778       # where the proxy subscribes (e.g. local strfry)
PUBLIC_RELAY_URL=wss://relay.powr.build  # what the proxy tells the NSE to fetch from
```

Place your APNs `.p8` key next to `proxy.js` with permissions `600`.

```bash
node proxy.js
# or: systemctl start clave-proxy
```

The proxy exposes:

- `POST /register` — NIP-98-authenticated. Body: `{"token": "<apns-device-token>"}`. Binds token to the pubkey from the NIP-98 event.
- `POST /unregister` — NIP-98-authenticated. Removes the token for the signing pubkey.
- `GET /health` — returns `{ok, uptime_seconds, total_tokens, unique_pubkeys, last_event_received_at}`.

### Run tests

iOS:

```bash
xcodebuild test -project Clave.xcodeproj -scheme Clave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ClaveTests
```

Proxy (requires Node ≥20.19):

```bash
cd relay-proxy
node --test test/*.js
```

## Pairing a client

### Bunker flow (recommended for most clients)

1. Open Clave → **Connect** → copy the Bunker URI (or scan the QR code)
2. Paste into the client's "connect with bunker" field
3. The first time the client connects, it sends your single-use secret with the `connect` request
4. Clave validates, saves the client as paired with Medium Trust + default method permissions, rotates the secret
5. Subsequent requests use the paired state — no secret needed

### Nostrconnect flow (for clients that want to initiate)

1. Client generates a `nostrconnect://` URI and shows it to you
2. Open Clave → **Connect** → paste the URI
3. Approval sheet shows the client's name, optional URL, and lets you choose Trust level + per-kind permissions
4. Tap Connect → Clave publishes an encrypted confirmation to the client's relay → client considers itself paired

## Related & prior art

- **[Amber](https://github.com/greenart7c3/Amber)** — the Android equivalent. Same idea, different platform constraints.
- **[nsec.app](https://github.com/nostrband/noauth)** — web-based signer, nsec in browser storage.
- **[nsecBunker](https://github.com/kind-0/nsecbunkerd)** — server-hosted signer. Trust model is different (you trust the operator).
- **Nostr NIPs** — [NIP-46 (Nostr Connect)](https://github.com/nostr-protocol/nips/blob/master/46.md), [NIP-44 (encryption)](https://github.com/nostr-protocol/nips/blob/master/44.md), [NIP-98 (HTTP auth)](https://github.com/nostr-protocol/nips/blob/master/98.md), [NIP-42 (relay auth)](https://github.com/nostr-protocol/nips/blob/master/42.md), [BIP-340 (Schnorr)](https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki).

## License

[MIT](LICENSE).

## Security

Please report security issues responsibly per [SECURITY.md](SECURITY.md) — not via public GitHub issues.

## Contributing

This is early-stage beta. Issues and PRs welcome, especially around:
- multi-relay publish for nostrconnect reliability
- per-client sign dedup (currently multi-publishing clients like Nostur can trigger duplicate prompts — see BACKLOG)
- macOS Catalyst / visionOS support
- npub/nprofile handling in the client detail view
