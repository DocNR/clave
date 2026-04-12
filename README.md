# Clave

Push-based iOS NIP-46 Nostr remote signer. Signs events while the app is fully killed.

## Why

iOS aggressively terminates background processes. Standard NIP-46 signers rely on a persistent WebSocket connection to receive signing requests — this is impossible on iOS when the app is not in the foreground. Workarounds like background fetch and silent push are unreliable and subject to OS throttling.

Clave solves this by inverting the model: a small Node.js proxy watches the relay for incoming NIP-46 requests and fires an Apple Push Notification. The push wakes a Notification Service Extension (NSE), which runs in its own process with a guaranteed ~30 seconds of execution time. The NSE decrypts the request, signs the event, and publishes the response — entirely without the app being open. The main app is only needed for initial key import and APNs registration.

## Architecture

```
Client App
    |
    | kind:24133 (NIP-46 request)
    v
Relay
    |
    | relay subscription
    v
relay-proxy (Node.js)
    |
    | APNs HTTP/2 push
    v
iPhone NSE wakes (app can be killed)
    |
    | decrypt NIP-46 request
    | sign event (secp256k1)
    | encrypt response
    v
Relay
    |
    v
Client App receives signed response
```

## Components

- `Clave/` — Main SwiftUI app. Key import/generation, APNs device token registration, permission request.
- `ClaveNSE/` — Notification Service Extension. Lightweight NIP-46 handler: decrypt, sign, publish response. Runs in its own process with no dependency on the main app.
- `Shared/` — Code shared between app and NSE: Keychain wrapper, crypto primitives, relay client, signer logic.
- `relay-proxy/` — Node.js script that subscribes to the relay for kind:24133 events addressed to the signer pubkey and fires APNs pushes.

## Crypto

- secp256k1 signing via `swift-secp256k1` (P256K) — lightweight enough to run inside the NSE
- NIP-44 encryption/decryption: inline ChaCha20-Poly1305 implementation, no external dependency
- URLSession WebSocket for relay communication (no third-party networking)

## Supported NIP-46 Methods

- `ping`
- `get_public_key`
- `sign_event`

All three verified end-to-end.

## Developer Setup

### Prerequisites

- Xcode 15+
- Physical iPhone (NSE requires real device for push notifications)
- Apple Developer account with push notification capability
- Node.js 18+

### Steps

1. Clone the repo and open `Clave.xcodeproj` in Xcode.

2. Configure signing for both the `Clave` and `ClaveNSE` targets using your team ID.

3. Enable the following capabilities on both targets:
   - App Groups: `group.dev.nostr.clave`
   - Push Notifications (main app target only)

4. Add the `swift-secp256k1` Swift Package to the project and link it to the `ClaveNSE` target.

5. Create an APNs authentication key (.p8) in the Apple Developer portal under Certificates, Identifiers & Profiles > Keys.

6. Install proxy dependencies and start the proxy:

   ```bash
   cd relay-proxy
   npm install
   SIGNER_PUBKEY=<hex-pubkey> \
   APNS_KEY_ID=<key-id> \
   APNS_TEAM_ID=<team-id> \
   APNS_KEY_PATH=./AuthKey.p8 \
   BUNDLE_ID=dev.nostr.clave \
   node proxy.js
   ```

7. Run the app on a physical iPhone and import or generate a Nostr private key. The app will register its APNs device token on launch.

8. Register the device token with the proxy:

   ```bash
   curl -X POST http://localhost:3000/register \
     -H "Content-Type: application/json" \
     -d '{"token":"<apns-device-token>"}'
   ```

9. Send a NIP-46 signing request from any compatible client (e.g. `clave-test` or another NIP-46 bunker client) pointed at the signer pubkey.

## Status

Proof of concept. End-to-end flow is working for `ping`, `get_public_key`, and `sign_event`. Not production-ready — key management, error handling, and multi-client support are minimal.
