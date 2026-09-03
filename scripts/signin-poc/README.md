# Sign in with Clave — proof-of-concept harness

Week-1 empirical tooling for
`docs/superpowers/specs/2026-09-02-sign-in-with-clave-design.md`. Run from a
laptop with Node 20+ (the CCR container's egress policy blocks relay
WebSockets, so these run on a dev machine):

```sh
cd scripts/signin-poc && npm install
```

## What proves what

| Script | Proves | Spec gate | Needs |
|---|---|---|---|
| `node relay-ephemeral-probe.mjs` | whether relay.powr.build (+damus, nsec.app) **stores kind:24133** or treats it as ephemeral — decides how much recovery weight the re-ack window carries vs. any relay-replay idea | Week-1 test 1 | laptop only |
| `node partner-sim.mjs` | the **whole existing-user concept with zero iOS diffs**: handshake ack against the shipped App Store build, the **resume probe** (`get_public_key` answers with no prompt), and the **lock-screen signing leg** (background the phone during `sign_event`, approve from the banner) | Week-1 test 2 (client half + probe regression) | laptop + iPhone with Clave |

`partner-sim.mjs` run cross-device is deliberate: the laptop's WebSocket never
freezes, so it isolates the protocol from the iOS same-device backgrounding
problem. What it does **not** prove: the same-device freeze/re-fire timing, the
zero-account stash-and-replay (needs the Phase-1 iOS diff), SKOverlay /
`canOpenURL` (needs a scratch partner app — week-1 test 3), and Smart-Banner
behavior on the real fallback page (test 4).

## Reading the probe result

- `stored1: true, stored24133: false` → relay stores normal events but not
  24133 ⇒ **ephemeral confirmed**; lost acks are unrecoverable from relays and
  the spec's re-ack window / resume probe carry recovery. (Expected outcome.)
- `stored24133: true` → relay keeps 24133 ⇒ a since-filter replay is viable as
  an *additional* recovery rung on this relay; note it in the spec.
- `stored1: false` too → the relay rejects unknown pubkeys or doesn't serve
  since-queries; the 24133 result is inconclusive there.

## partner-sim flags

`--relay wss://…` (repeatable; default relay.powr.build) · `--perms
sign_event:1` · `--multi` (accounts=multi accumulate window) · `--no-sign` ·
`--window 300` (listen seconds) · `--print-only` (mint + QR, no network).

Cleanup after a run: unpair **Signin PoC** from the account's connected
clients in Clave. The kind:1 the signer returns is verified locally and never
published.
