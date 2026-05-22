# Multi-Relay Bunker — break the single-relay pin

_2026-05-22 — design spec for Tier 3 of the Amber-parity gap analysis. Clave's `bunker://` flow currently pins every paired client to one relay (`wss://relay.powr.build`) because the push proxy subscribes to exactly that relay. If that relay drops a kind:24133 request, or a client can't reach it, signing silently fails. This spec makes the bunker path multi-relay end-to-end: bunker URIs advertise a relay set, the proxy subscribes to all of them with cross-relay dedup, and responses publish back to the relay the request arrived on. NIP-46 already assumes multiple relays; this brings Clave's bunker path in line._

## Context

Clave has two pairing flows with very different relay behavior:

- **`nostrconnect://`** — the *client* specifies the relays in its URI; Clave connects to and publishes on exactly those (`AppState+NostrConnect.swift`, `RelayUtils.connectToRelays`). This path is already multi-relay because the client drives it.
- **`bunker://`** — Clave/the proxy drives it. The proxy subscribes to a **single** relay (`RELAY_URL` in `relay-proxy/.env`) and the bunker URI it generates points clients at one `PUBLIC_RELAY_URL` = `wss://relay.powr.build` (`SharedConstants.relayURL`, `SharedConstants.swift:7`). The Settings "Relay" row is **display-only** (`SettingsView.swift:317-325`).

The README names this directly as a known limitation: *"Bunker flow pins to `wss://relay.powr.build` — the proxy subscribes to one relay, so clients paired via `bunker://` must publish kind:24133 requests there. … multi-relay bunker support is backlogged."*

Why it matters: a single relay is a single point of failure for the entire bunker user base. Relay restarts, rate-limits, regional reachability, or an ephemeral-event drop all turn into "signing just doesn't work" with no client-visible cause. NIP-46 clients generally expect to reach a signer across a set of relays; Amber and other signers operate multi-relay. This is the top reliability item for bunker, and it's already on the backlog.

## How signing flows today (the relevant slice)

```
client ──kind:24133 (NIP-44 to signer)──▶ relay.powr.build
                                              │
proxy subscribes to relay.powr.build ◀────────┘
   │  routes by #p tag → APNs push {relay_url, event_id}
   ▼
iPhone NSE wakes → fetches event_id from relay_url → decrypts → signs
   → publishes response (NIP-44 to client) ──▶ relay.powr.build ──▶ client
```

Every arrow above is bound to one relay. The push payload even carries a single `relay_url` (README "How it works"). Multi-relay means generalizing each arrow to a *set*, with dedup so one logical request isn't processed N times.

## Goals

- **Bunker URIs advertise multiple relays.** Generated `bunker://` URIs include several `relay=` parameters (a small, healthy default set), so a client publishes/subscribes across all of them per NIP-46.
- **Proxy subscribes to the full set.** The proxy maintains kind:24133 subscriptions across all configured relays and **deduplicates by event id** so one request published to three relays produces exactly one push.
- **Responses go back where the request came from.** The NSE publishes its response to the relay the request was fetched from (at minimum), ideally to the client's known relay set, so the client — which may be listening on a subset — actually receives it.
- **Tolerate partial relay failure.** If some relays are down/slow, the flow still succeeds as long as one healthy relay carries the request and one carries the response. No hard dependency on any single relay.
- **(Stretch) user-visible relay set.** Turn the display-only Settings "Relay" row into a managed list (view the active set; later, edit). Editing has proxy-coordination implications — see Non-goals/phasing.

## Non-goals

- **No arbitrary user-supplied relays without proxy support (this round).** The proxy can only push for relays it subscribes to. A user can't point bunker at a relay the proxy doesn't watch and expect delivery. Fully user-defined bunker relays require dynamic per-pubkey subscription management on the proxy — a separate, larger effort (see Future).
- **No NIP-65 outbox-model routing.** We're fanning out across a fixed healthy set, not computing per-recipient relay lists from kind:10002.
- **No change to the `nostrconnect://` path.** It's already multi-relay (client-driven). This spec is about the bunker/proxy path.
- **No change to the encryption or auth model.** Still NIP-44 end-to-end, still NIP-98-authenticated registration. Only relay *fan-out* changes.
- **No new event kinds or RPC verbs.**

## Design

### URI shape

Bunker URI generation (the per-signer accessor referenced in the multi-account work, `AppState.bunkerURI(for:)`) emits multiple relays:

```
bunker://<signer_pubkey>?relay=wss://relay.powr.build&relay=wss://relay.nsec.app&relay=wss://relay.damus.io&secret=<single-use>
```

The relay set comes from a `SharedConstants.defaultBunkerRelays` list (replacing the single `relayURL` for bunker purposes). Keep the set small (≈2–3) and chosen for reliability + ephemeral-event tolerance. `relay.powr.build` stays in the set so **existing paired clients keep working** (back-compat — see Migration).

### Proxy: multi-subscribe + dedup

The proxy moves from one `RELAY_URL` to a `RELAY_URLS` list:

- Open and maintain a kind:24133 subscription on each relay, with reconnect/backoff per relay (independent — one relay flapping doesn't drop the others).
- **Dedup by event id:** the same kind:24133 event arrives on multiple relays. Maintain a short-lived seen-set (TTL a few minutes, bounded size) keyed by event id; only the first occurrence triggers an APNs push. This is the central correctness mechanism — without it, a client publishing to 3 relays causes 3 pushes / 3 signings.
- `/health` gains per-relay connection status so operators can see partial outages.

### Push payload: relay set, not a single relay

The push currently carries `{relay_url, event_id}`. Generalize to carry the relay (or relays) the event was seen on so the NSE knows where to fetch and where to respond. Keep it content-free (still just routing metadata, never decrypted content). The NSE fetches `event_id` from the carried relay(s), trying the next on failure.

### NSE: response fan-out

On the response side, the NSE publishes to the relay it fetched the request from, and SHOULD also publish to the other relays in the bunker set, because the client may be subscribed on a different subset. Publishing is best-effort and idempotent (the response event has a stable id); duplicates are harmless and the client dedups. This mirrors the existing `nostrconnect` path, which already publishes to all client-named relays (`RelayUtils.publishEventToRelays`).

> Budget note: this stays within the NSE's ~30 s window — connecting to ≈3 relays and publishing one response is comparable to today's `nostrconnect` flow. The plan should measure worst-case multi-relay connect time on a real device to confirm headroom.

### Settings surface (phased)

- **Phase A (read):** replace the display-only single relay (`SettingsView.swift:317-325`) with the active bunker relay *set*, read-only, plus the per-relay health from `/health`. Low risk, immediately useful.
- **Phase B (edit) — stretch:** allow the user to choose among proxy-supported relays. Because delivery requires the proxy to subscribe, "editing" in Phase B means selecting from the proxy's known set, not typing arbitrary URLs. Fully arbitrary relays are Future work.

## Migration / backwards compatibility

- **Existing paired clients** hold bunker URIs that name only `relay.powr.build`. Keeping that relay in the default set means they keep working with **no re-pair required**. New pairings get the multi-relay URI.
- **Proxy rollout** is backward compatible: `RELAY_URLS` defaults to `[RELAY_URL]` if the new var is unset, so an un-migrated proxy behaves exactly as today.
- **Old NSE + new URI:** an older app build that still expects a single `relay_url` in the push must keep working. Generalizing the payload should be additive (keep `relay_url` as the first/primary entry, add an optional `relays` array), so a stale NSE reads the primary and a new NSE reads the set.

## Risks / open questions

1. **Relay tolerance for ephemeral kind:24133.** Not all relays reliably accept/serve ephemeral events. The default set must be vetted (probe `relay.powr.build`, `relay.nsec.app`, `relay.damus.io`) before shipping. This is the same probe flagged in the multi-account NostrConnect spec — coordinate.
2. **Dedup correctness & memory.** The seen-set TTL must exceed plausible inter-relay arrival skew but stay bounded. Too short → double-push; too long → memory growth. Pick a TTL (suggest a few minutes) and cap size with LRU eviction.
3. **Proxy resource use.** N subscriptions × many pubkeys is more sockets and traffic. Quantify for the current user base; subscriptions are per-relay not per-pubkey, so the multiplier is small (× number of relays).
4. **Response delivery vs. client subscription subset.** If a client only listens on relay X but the NSE responds only on relay Y, the client misses it. Fan-out on response mitigates; the safe rule is "respond on the request's relay AND the rest of the set."
5. **Push payload size / format change.** Coordinate the additive payload change across proxy + NSE so a mixed-version fleet (old app, new proxy and vice-versa) stays correct.
6. **Default relay set selection.** Which relays, how many? Reliability and ephemeral-event support trump count. Start at ≈2–3.

## Out of scope / future work

- **Fully user-defined bunker relays** with dynamic per-pubkey proxy subscription management — the proper "bring your own relay" feature; needs the proxy to subscribe on demand.
- **NIP-65 / outbox-model** response routing using the client's advertised read relays.
- **Per-account relay sets.** This spec uses one device-wide default set; per-account customization is a later refinement.
- **Relay health-based auto-selection** (drop a relay from the active set when it's been unreachable for a while). Nice once Phase A surfaces health.

## Plan + verification

Implementation plan to follow in the house `superpowers` plan format after review. The work spans **two components** (Node.js proxy + iOS NSE/app), so the plan will sequence proxy-first (backward-compatible `RELAY_URLS` + dedup, defaulting to today's behavior), then the URI/NSE changes. Anticipated verification:

- Proxy unit/integration: same event id arriving on multiple relay subscriptions yields exactly one push (dedup); per-relay reconnect on socket drop; `RELAY_URLS` unset ⇒ single-relay behavior identical to today; `/health` reports per-relay status.
- iOS unit: bunker URI contains the full relay set; push-payload parsing reads the relay set with the legacy single-`relay_url` still honored.
- End-to-end (real device): pair a client via the new multi-relay bunker URI; publish a signing request to relay A only → signs; to relay B only → signs; to all → signs **once** (dedup); take one relay offline → still signs via the others; confirm an existing (pre-migration) paired client still signs against `relay.powr.build` with no re-pair.
