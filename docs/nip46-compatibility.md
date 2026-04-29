# NIP-46 Client Compatibility (Clave)

_Last updated: 2026-04-29 — statuses reflect Clave build 29 unless noted otherwise._

This document tracks how Nostr clients interoperate with Clave's NIP-46 signer. It is **Clave-centric**: every status row reflects what we have actually tested against Clave specifically. Other NIP-46 signers (Amber, nsec.app, etc.) may behave differently with the same client.

When a client doesn't work, we try to attribute the issue to one of four buckets:

- **signer-side** — Clave's implementation is at fault.
- **client-side** — the client's NIP-46 implementation has a bug.
- **library-shared** — a bug in a Nostr library that the client (and possibly other clients) depends on. Distinct from "client-side" because the fix lands upstream of the client.
- **spec-ambiguity** — the NIP-46 spec permits both behaviors and the two implementations chose differently.

The triage guide below has more detail on how to tell these apart — and why "the bug isn't in our signer" is harder to prove than it sounds.

---

## Compatibility matrix

| Client | Platform | Library family | Connect modes | Status | Issue attribution |
|---|---|---|---|---|---|
| [Nostur](https://nostur.com) | iOS | NDK-iOS / nostr-essentials | bunker | ✅ Works | — |
| [fevela.me](https://fevela.me) | Web | nostr-tools (recent) | bunker, nostrconnect | ✅ Works | — |
| [noStrudel](https://nostrudel.ninja) | Web | applesauce-signers | bunker, nostrconnect (non-`relay.nsec.app` URI) | ⚠️ Partial — see [notes](#nostrudel) | client-side (relay-specific) |
| [Coracle](https://coracle.social) | Web | welshman | bunker, nostrconnect | ⚠️ Partial — see [notes](#coracle) | library-shared (welshman) |
| [zap.cooking](https://zap.cooking) | Web | custom wrapper over NDK | bunker | ⚠️ Partial — see [notes](#zapcooking) | client-side |
| [plebs vs. zombies](https://plebsvszombies.cc) | Web | nostr-tools (old, ~2.17) | bunker | ⚠️ Partial — see [notes](#plebs-vs-zombies) | library-shared (old nostr-tools) |
| [YakiHonne](https://yakihonne.com) | Web (+ mobile?) | NDK | bunker, nostrconnect | ⚠️ Partial — see [notes](#yakihonne) | unknown |
| [Primal](https://primal.net) | Web / iOS / Android | nostr-tools (recent, inferred) | bunker, nostrconnect | ❓ Untested end-to-end | — |
| [Snort](https://snort.social) | Web | nostr-tools (inferred) | bunker, nostrconnect | ❓ Untested end-to-end | — |
| [Amethyst](https://github.com/vitorpamplona/amethyst) | Android | (Amber-shaped, inferred) | bunker | ❓ Untested with Clave | — |

**Status meanings:**

- ✅ **Works** — bunker and (where supported) nostrconnect pairing succeed and signing requests complete end-to-end on Clave's most recent TestFlight build.
- ⚠️ **Partial** — at least one path (typically nostrconnect) has a known issue. The bunker path generally works as a fallback. See per-client notes for the workaround.
- ❌ **Broken** — neither pairing path completes. Currently no entries in this state; clients that fall here usually have a workaround that demotes them to ⚠️ Partial.
- ❓ **Untested** — we have not exercised this client end-to-end. May work fine; just not verified.

---

## Per-client notes

### noStrudel

**Symptom:** nostrconnect pairing UI stalls when the URI relay is `wss://relay.nsec.app`.

**Investigation:** triangulation across signers showed the bug is signer-agnostic. nsec.app's signer with the same `relay.nsec.app` URI also stalls noStrudel; nsec.app's signer with the same URI works fine in Coracle. The failing combination is specifically `applesauce-signers` (the library noStrudel uses) plus `relay.nsec.app` — Clave is not unique here.

**Workaround:**

- Use a different relay in noStrudel's nostrconnect URI configuration. `relay.powr.build`, `nos.lol`, and `damus.io` all confirmed working.
- Or pair via Clave's `bunker://` URI instead, which embeds `relay.powr.build` and bypasses the bug.

**Attribution:** client-side, but specifically tied to one library + one relay combination. Worth filing upstream against [applesauce-signers](https://github.com/hzrd149/applesauce); not yet filed.

---

### Coracle

**Symptom:** nostrconnect pairing UI stalls indefinitely after the connect handshake. The signer publishes the response, the relay accepts it, but Coracle's UI never advances.

**Investigation:** Coracle uses [welshman](https://github.com/coracle-social/welshman) for relay management. welshman treats any non-null `switch_relays` response from the signer as a migration trigger and reorganizes its connection pool — even when the new list is a strict subset of the current pool. The migration logic stalls. We confirmed via two test paths that returning `null` from `switch_relays` is the only UI-safe response for welshman-backed clients. Clave shipped this fix in [PR #7](https://github.com/DocNR/clave/pull/7); other signers that return `["wss://..."]` from `switch_relays` will still stall Coracle.

**Workaround:** pair via Clave's `bunker://` URI. This still works because the bunker URI embeds Clave's relay directly and the post-pair flow doesn't depend on `switch_relays`.

**Attribution:** library-shared (welshman). Spec ambiguity contributes — NIP-46 doesn't mandate what a signer must return from `switch_relays`, but the most permissive return (`null`) interoperates best.

---

### zap.cooking

**Symptom:** pairing via nostrconnect appears to succeed but signing requests don't reach Clave.

**Investigation:** zap.cooking uses NDK as a base but wraps it with a custom `authManager` that does its own manual pairing (subscribe + decrypt the connect response) before handing off to NDK's signer. The custom wrapper doesn't call NDK's full `blockUntilReady` flow, so `switch_relays` is never invoked — meaning the client doesn't migrate to Clave's relay after pairing, and subsequent `sign_event` RPCs go to relays the proxy doesn't watch.

There's also a separate concern: the wrapper swallows decrypt failures silently and proceeds with pairing regardless. This is a security weakness (an attacker publishing a matching `#p` event before the legitimate signer responds could hijack the session) — independent of the Clave compat issue.

**Workaround:** pair via Clave's `bunker://` URI.

**Attribution:** client-side. Tracked as a zap.cooking bug; not Clave-fixable.

---

### plebs vs. zombies

**Symptom:** nostrconnect pairing succeeds but signing doesn't reach Clave.

**Investigation:** plebsvszombies.cc bundles `nostr-tools ^2.17.0`, an older version whose `BunkerSigner.fromURI` predates `switch_relays`. The client never asks the signer to migrate, so it keeps publishing `sign_event` RPCs to whatever relay was in the original URI — typically not Clave's relay. NDK-based clients and recent `nostr-tools` builds don't have this issue because they call `switch_relays` after pairing.

**Workaround:** pair via Clave's `bunker://` URI, which sets the relay context up-front.

**Attribution:** library-shared (old nostr-tools). Resolvable upstream by upgrading `nostr-tools` past the version that introduces `switch_relays` in `fromURI`. NIP-46 spec marks `switch_relays` as OPTIONAL, so this is "spec-allowed but interop-hostile" rather than a strict bug.

---

### YakiHonne

**Symptom:** the signer's response reaches `relay.nsec.app` (relay returns `OK true`), but YakiHonne's UI never observes it. Pairing stalls or signing requests time out.

**Investigation:** unclear whether the relay drops the forwarded event before YakiHonne's subscription receives it, or whether YakiHonne's response handler silently ignores it. We have not been able to reliably reproduce against a non-`relay.nsec.app` URI.

**Workaround:** unclear — bunker URI usually unblocks pairing, but if YakiHonne's signing path also depends on `relay.nsec.app`, the issue can recur. Amber's retry-with-re-encryption pattern mitigates this on Android; Clave does not currently retry.

**Attribution:** unknown — not yet narrowed to client / library / relay.

---

## Library family notes

Cross-cutting patterns observed during compatibility testing. Useful for predicting behavior of an untested client based on its underlying library.

### NDK (`@nostr-dev-kit/ndk`)

- Subscribes to the URI's relays on `connect`, calls `switch_relays` after pairing, honors the response cleanly (updates `relayUrls`, restarts subscription on the new set).
- Handles a `null` return from `switch_relays` correctly (interprets as "stay on current relays").
- Most NDK-based clients work end-to-end with Clave on both bunker and nostrconnect paths.

### nostr-tools (recent)

- `BunkerSigner.fromURI` calls `switch_relays` and migrates the subscription on success.
- Works end-to-end with Clave. Confirmed with fevela.me; expected to work with Primal and Snort (untested).

### nostr-tools (old, ~2.17)

- `BunkerSigner.fromURI` predates `switch_relays`. Client stays on whatever relays were in the URI; never migrates.
- Clients pinned to this version cannot use Clave's nostrconnect path successfully unless the URI already contains `wss://relay.powr.build`. Bunker URI works because it embeds the relay.
- Detection: in the bundled JS, look for `setupSubscription(s),l(r)` adjacent with no `switchRelays` call between them.

### welshman (Coracle)

- Treats any non-null `switch_relays` response as a migration trigger. Migration logic stalls the connection pool, freezing the pairing UI.
- Returning `null` from the signer's `switch_relays` is the only UI-safe response for welshman-backed clients.
- Even when the returned relay set is a strict subset of the client's current pool, welshman still triggers migration and stalls. This was verified by replaying the client's own URI relay back to it.

### applesauce-signers (noStrudel, others)

- General handshake works against most relays.
- Specific bug: when the URI relay is `wss://relay.nsec.app`, the client never advances past the connect ack — appears unrelated to the signer (reproduces with both Clave and nsec.app).
- Workaround: configure noStrudel's nostrconnect relay to anything else.

### rust-nostr (`nostr-sdk`, `nostr-sdk-swift`, ≤ 0.44.2)

- `ResponseResult::parse` for the `connect` method strictly requires the response to be `"ack"`. Per NIP-46 spec, signers may return `"ack"` OR the URI's `secret` echoed back. Both Clave and nsec.app return the latter, so rust-nostr clients on this version cannot complete a `bunker://` connect against a spec-compliant signer.
- Master has a partial fix on the parser side, but `nostr-connect/src/client.rs::connect()` still calls `res.to_ack()?` which only accepts `Self::Ack`. As of 2026-04-22 (no tagged release > 0.44.0), bunker:// remains broken on master too.
- The `nostrconnect://` path on rust-nostr has a different code path and is reportedly working.
- Workaround: client authors can vendor a slim NIP-46 client (POWR did this — ~300 lines) and plug it into rust-nostr's `NostrSigner.custom(...)` factory until upstream lands a release.

### Custom wrappers

- Behavior is per-implementation. zap.cooking's wrapper bypasses NDK's pairing flow and skips `switch_relays`, breaking nostrconnect with Clave (see [notes](#zapcooking) above).
- If you're building a custom NIP-46 client, the safest path is: use NDK's or nostr-tools's full pairing helper unchanged. The protocol has subtle ordering requirements (decrypt the connect response before considering the session paired; honor `switch_relays`; rotate pairing secrets after first use) that are easy to get wrong.

---

## Triage guide: signer-side, client-side, library-shared, or spec-ambiguity?

When a Nostr client doesn't work with Clave, the natural first question is "whose bug is it?" The honest answer is that this is harder to determine than it sounds. Below is the workflow we use.

### Step 1 — Reproduce with two different signers

Test the same client against Clave AND a second NIP-46 signer (Amber, nsec.app, nsecBunker). The result narrows the search:

- **Both signers work** → the client has no bug. If you saw a problem earlier, it was probably transient (relay flake, network).
- **Only Clave fails** → likely signer-side (Clave). File a bug using the [NIP-46 broken client template](https://github.com/DocNR/clave/issues/new?template=nip46-broken-client.md).
- **Both signers fail** → does NOT immediately mean the client is buggy. Continue to Step 2.

### Step 2 — Check whether the signers share a library on the receive side

This is the step that the simple "different signer = different result" heuristic misses. A bug can fail across multiple signers if those signers happen to depend on the same Nostr library.

Examples:

- The rust-nostr `connect` ack issue affects every signer that returns the URI secret instead of `"ack"` — Clave AND nsec.app both fail against rust-nostr-based clients. Not a Clave-specific bug; not even client-specific. It's a library bug.
- If a future bug surfaces in NDK's NIP-46 RPC layer, every NDK-based signer will exhibit it identically. That looks signer-side from the client's perspective but the fix lands upstream.

To check: look at each signer's source (or known library) and see whether they share a NIP-46 implementation. If yes → likely **library-shared**.

### Step 3 — If different libraries fail the same way, suspect client-side or spec-ambiguity

If two signers built on different libraries (e.g. Clave's hand-written NIP-46 vs Amber's) both fail against the same client in the same way, the bug is most likely:

- **Client-side** — the client itself is doing something non-spec-compliant. Triage by looking at the client's NIP-46 handler and comparing against the spec.
- **Spec-ambiguity** — the spec permits the signers' behavior and the client's behavior, but the two don't compose. These are the hardest to fix because there's no "wrong" implementation, just an interop gap. Worth raising on [nostr-protocol/nips](https://github.com/nostr-protocol/nips) for a spec clarification.

### Step 4 — When in doubt, file two bugs

If you can't disentangle signer-side from library-shared from client-side, file an Issue on Clave's repo (we'll triage). If we identify it as upstream, we'll re-file against the appropriate library/client and link both Issues so it's tracked in one place.

---

## Open upstream issues / PRs

Public list of issues filed against client/library repos for NIP-46 bugs surfaced during Clave testing. Empty rows for issues we know about but haven't filed yet — patches welcome.

| Issue | Library / Client | Status | Filed |
|---|---|---|---|
| Bunker `connect` parser strictly requires `"ack"`, rejects spec-allowed echoed-secret response | rust-nostr | Open / partial fix on master as of 2026-04-22 | _not yet filed by us — bug confirmed via independent NIP-46 probe testing_ |
| `applesauce-signers` + `relay.nsec.app` connect-ack stall | noStrudel / applesauce | Not yet filed | — |
| welshman treats non-null `switch_relays` as migration trigger | Coracle / welshman | Not yet filed | — |
| Custom authManager bypasses NDK pairing flow + decrypt-swallow | zap.cooking | Not yet filed | — |

Once issues are filed, the rightmost columns will link to them.

---

## Untested but reportedly NIP-46-supporting

Clients from [awesome-nostr](https://github.com/aljazceru/awesome-nostr) that advertise NIP-46 / bunker support but haven't been exercised against Clave. Adding them to the matrix above as `❓ Untested` is a backlog item; we expand entries as we test them or as community reports come in.

A non-exhaustive list (PRs adding clients here are welcome):

- **Web:** Nostromat, Iris, Nos.social, Habla.news, Highlighter, zap.stream, Listr, Snort (claimed but untested with Clave), Coracle (tested, see above)
- **Mobile:** YakiHonne mobile (web tested), 0xchat, Damus (NIP-46 support unclear)
- **Specialized:** Pinstr, Bookmarkstr, marketplace clients (Plebeian Market, Shopstr)

If you've used Clave with a client not listed above, please [open a PR](#contributing) adding a row to the matrix.

---

## Contributing

There are three ways to contribute to this document.

### Report a broken client

Open a [GitHub Issue](https://github.com/DocNR/clave/issues/new?template=nip46-broken-client.md) using the **NIP-46 broken client** template. The template asks for:

- Client name and URL
- Platform (web / iOS / Android / desktop)
- Signer used (Clave bunker / Clave nostrconnect / other)
- Clave build number (visible in Settings → tap the version row)
- What you expected and what happened
- Console errors (web clients) or screenshots
- Reproducer steps if you can isolate them

Once triaged we'll either add a row to the matrix or, for issues we can fix, ship a Clave update and update the row.

### Add a new client to the matrix

Open a PR editing this file. Required for the row:

- Verified status against a specific Clave build (don't assume an old build's behavior carries forward — the protocol is fluid)
- Library family if you can identify it (look at the client's GitHub for `package.json` deps, or open the bundled JS and grep for `nostr-tools` / `@nostr-dev-kit/ndk` / `welshman` / etc.)
- One-line reproducer steps in the per-client notes section if status isn't ✅

### Update an existing row

Open a PR that:

- Updates the row's status, build tested, or notes
- Bumps the `Last updated` date at the top of this file
- Adds a one-line entry to the changelog at the bottom (below)

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-29 | Initial publication. Build 29. |

---

## Acknowledgments

Thanks to [@bfgreen](https://github.com/bfgreen) for testing across many builds — most rows in the matrix above have been independently verified by them.

---

## See also

- [Clave repository](https://github.com/DocNR/clave) — source code and issue tracker
- [SECURITY.md](../SECURITY.md) — responsible disclosure policy
- [NIP-46 specification](https://github.com/nostr-protocol/nips/blob/master/46.md)
- [NIP-44 specification](https://github.com/nostr-protocol/nips/blob/master/44.md) — the encryption layer used by NIP-46
- [awesome-nostr](https://github.com/aljazceru/awesome-nostr) — community-maintained list of Nostr clients
