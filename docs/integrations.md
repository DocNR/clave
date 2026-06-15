# Integrating Clave as your Nostr signer

This doc covers what NIP-46 client developers need to know to support Clave end-to-end, including the multi-account NostrConnect extension that Clave introduced as of build 80.

## Single-account NostrConnect (standard NIP-46)

Standard `nostrconnect://` flow per [NIP-46](https://github.com/nostr-protocol/nips/blob/master/46.md). Build a URI with the client's ephemeral pubkey, the relays you'll listen on, and a per-handshake `secret`. Subscribe to kind:24133 events tagged `#p:client_pk`. Validate the first ack matches your `secret`. Open a session keyed `(client_pk, signer_pk)`.

Clave returns `result: "<echoed_secret>"` as a plain string in this flow — exactly the form most NIP-46 client libraries already expect.

See `docs/nip46-compatibility.md` for known per-client and per-library quirks (NDK bunker handshake bug, old `nostr-tools` versions, etc.).

## Multi-account NostrConnect (`accounts=multi`)

Clave supports an opt-in extension that lets one client pairing produce N parallel signer sessions in one user flow. The user picks N accounts in Clave's `.multi`-mode picker, and Clave emits one kind:24133 `connect` ack per selected account — all tagged with the same client pubkey, each signed by a distinct signer.

### URI format

Add `accounts=multi` as a query parameter:

```
nostrconnect://{client_pk}?relay=wss://...&secret={secret}&accounts=multi&perms=...&name=...
```

Old Clave installs (pre-build-80) ignore the unknown parameter and degrade gracefully to single-account behavior (one ack arrives). Clients without `accounts=multi` see today's single-account flow.

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

A client that fails to parse the JSON (e.g. `JSON.parse` throws) should fall back to treating `result` as a plain string and string-compare against the URI secret. Pattern:

```ts
let echoed: string | undefined;
let name: string | undefined;
let picture: string | undefined;
let total: number | undefined;
if (result.startsWith("{")) {
  try {
    const parsed = JSON.parse(result);
    echoed = parsed.echoed_secret;
    name = parsed.name;
    picture = parsed.picture;
    total = typeof parsed.total === "number" ? parsed.total : undefined;
  } catch { /* malformed — treat as bare secret */ }
} else {
  echoed = result;
}
if (echoed !== uriSecret) return;  // handshake validation failed
```

### Listening-window expectation

The standard NIP-46 client library pattern is "subscribe, resolve on first matching ack, unsubscribe." For multi-account, the client MUST instead **accumulate** acks within a listening window:

- Recommended window: **60 seconds**, with an explicit Done button to short-circuit.
- Keep the kind:24133 subscription open for the full window — do NOT unsubscribe on the first ack.
- For each received ack: validate `echoed_secret` matches the URI secret. Parse optional `name` / `picture` / `total`. Store the `(signer_pk, name, picture)` tuple as one of the user's accounts.
- On `count == total` (auto-finalize) OR window expiry OR user-tapped Done: close the subscription and surface the resulting accounts list to the user.

A reference implementation lives in the Spectr codebase (shipped as the **Jank** app, https://jank.army) at `src/providers/NostrProvider/login-flows.ts` (function `nostrConnectionLoginMulti`). Spectr targets `nostr-tools` underneath; the accumulator overrides the library's first-ack-completes default.

### Show progress while listening

Mirror Clave's per-iteration progress UI on the client side so the user knows pairing isn't done:

```
1 connected, listening for more (53s)…
[Done]
```

This is the user-visible counterpart to Clave's "Pairing 2 of 4…" progress. The Done button is the explicit escape if Clave over-promises `total` or a relay drops an ack.

### Per-signer session state

Subsequent `sign_event` / `nip04_decrypt` / `nip44_decrypt` RPCs are encrypted to the specific signer pubkey, exactly as in single-account NIP-46. Each pair `(client_pk, signer_pk)` is a distinct session. Clients with their own per-account signer registry (e.g. Spectr's `client.signers`) populate N entries from one multi-account pairing.

### Backwards compatibility

| Signer | Client URI | Result |
|---|---|---|
| Phase 2+ Clave (build ≥ 80) | URI without `accounts=multi` | Byte-identical to pre-Phase-2 / single-account behavior |
| Phase 2+ Clave | `accounts=multi` URI | Multi-account flow per this doc |
| Pre-Phase-2 Clave (≤ build 79) | `accounts=multi` URI | Unknown param ignored, falls back to single-account (graceful) |
| Other signers (Amber, nsec.app, etc.) | `accounts=multi` URI | Each implementation handles unknown params per its own tolerance. None are known to fail-hard on unknown URI params today. |

The single-account flow is bit-preserved across the Phase 2 upgrade — clients that don't opt in see exactly today's behavior.

### Spec / NIP draft status

This extension is not yet a formal NIP. A draft will be filed after Phase 2 ships and Spectr validates end-to-end. The shape documented above is the wire contract Clave commits to; clients integrating against this doc target the production Clave protocol.

## Client metadata in bunker `connect` (proposed NIP-46 extension)

> **Status: proposed.** A NIP-46 PR adding this param is in review (see [Spec status](#spec-status) below). Clave's signer already reads the shape described here, so clients can adopt it now and degrade gracefully on signers that don't.

In the `nostrconnect://` flow the client advertises its identity in the URI (`name`, `url`, `image`). The `bunker://` flow has no equivalent — the client only sends a `connect` request — so bunker-paired connections arrive at the signer with no name and show a generic label. This extension closes that asymmetry by letting the client attach the same three fields to its `connect` request.

### Wire format

Add an optional 4th parameter to the `connect` request — a JSON-stringified object mirroring the `nostrconnect://` metadata fields:

```json
{
  "id": "<random>",
  "method": "connect",
  "params": [
    "<signer_pubkey>",
    "<secret>",
    "<perms>",
    "{\"name\":\"Jank\",\"url\":\"https://jank.army\",\"image\":\"https://jank.army/icon.png\"}"
  ]
}
```

- **`params[3]` is a JSON _string_** (`JSON.stringify({...})`), not a nested object. Every element of `params` must stay a string — Clave decodes `params` as `string[]` and discards the whole array if any element is an object.
- **Keys are `name`, `url`, `image`** — the same names as the `nostrconnect://` query parameters (note `image`, not `imageURL`/`picture`).
- All three fields optional; omit them or send empty strings (Clave treats empty strings as absent).
- **Keep the perms slot.** To send metadata without requesting permissions, pass an empty string for `params[2]` so metadata occupies the fourth position.

### Signer behavior (Clave)

- Clave captures the metadata into the connection's `(name, url, image)` **at first pair** and uses `name` as the connection label.
- **Re-pair does not overwrite** stored metadata — the in-app connection name is user-editable and is the source of truth, so a reconnect can't clobber a rename. To refresh metadata, unpair and pair again.
- The metadata is **client-supplied and unauthenticated** (the client pubkey in a bunker pairing is an ephemeral throwaway). Clave treats it as a display hint only and never uses it for trust / auto-sign decisions; clients should expect any signer to do the same.

### Backwards compatibility

| Signer | Client `connect` | Result |
|---|---|---|
| Clave (with this change) | 3-param `connect` | Today's behavior — connection is unnamed until the user labels it |
| Clave (with this change) | 4-param `connect` | Connection labeled with the client's `name` at first pair |
| Signers without this change | 4-param `connect` | Extra param ignored; pairing proceeds normally |

The change is additive and adds no round-trip — the metadata rides on the existing `connect` request, so it can't extend or stall the handshake.

### Reference implementations

- **Signer:** Clave (this repo) — `Shared/LightSigner.swift`, function `extractConnectMetadata`.
- **Client:** Jank (https://jank.army).

### Spec status

Filed as a proposed NIP-46 extension (optional 4th `connect` param). Until it merges, the shape above is what Clave's signer reads; it may change to track review feedback, but any change stays backward-compatible — unknown or extra params are ignored on both sides.

## Reporting interop issues

For questions or compatibility issues, see `docs/nip46-compatibility.md` for known per-client quirks, or open a NIP-46 interop issue:

https://github.com/DocNR/clave/issues/new?template=nip46-interop-issue.md
