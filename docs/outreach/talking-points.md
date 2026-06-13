# Clave talking points

_Message reference for anyone posting about Clave. Plain-language first; technical depth at the bottom. The "never say" list at the end is binding for all official posts._

## The one-liner

> **Clave keeps your Nostr key locked in your iPhone's Keychain. Apps ask it for signatures — they never get the key.**

Variations by audience:

- **For Nostr users:** "Stop pasting your nsec into every app. Pair them with Clave instead — one tap, and the app can post as you without ever seeing your key."
- **For Android-familiar users:** "Amber, for iOS. Same idea — your key lives in one signer app, everything else connects to it. Amber relies on Android's NIP-55 app-to-app intents; iOS has no equivalent and its URL schemes are unreliable, which is exactly why Clave needed a different mechanism — a push-woken extension — to do the same job."
- **For developers:** "An iOS NIP-46 remote signer that works with the app closed: APNs wakes a Notification Service Extension for ~30 seconds to decrypt, check permissions, sign, and respond. No silent-audio hacks, no foreground requirement."
- **For privacy folks:** "Open source (MIT), end-to-end encrypted, code open for anyone to audit. The push payload is content-free — the server can't read your requests and can't sign as you, because it never has your key."
- **For multi-account users:** "Run more than one Nostr identity? Pair an app with Clave once and sign in with all your accounts in a single flow — each one stays a separate key, none of them ever leave your phone."

## The problem (why anyone should care)

1. **Your Nostr key is your identity, and it can't be rotated.** Lose a password, you reset it. Lose your nsec, that identity is gone forever — followers, reputation, DMs, all of it.
2. **The common practice is pasting that key into every app you try.** Five apps means five copies of the one secret that can never be changed. Any one of them being malicious, buggy, or compromised is game over.
3. **The existing fixes don't fit iOS.** Browser extensions don't exist on iPhone. Hosted signers mean someone else holds your key. And iOS kills background apps, which is why an Amber-style signer didn't exist here — until now.

## How Clave works, in plain words

The **notary analogy** (use this one — it lands):

> Think of Clave as a notary that lives in your phone. Apps bring documents to be stamped. The notary checks who's asking and what they're asking for, stamps it, and hands it back. **Nobody ever borrows the stamp.**

Slightly more technical, still accessible:

> When an app needs something signed, it sends an encrypted request through a Nostr relay. A small server notices the request and sends your iPhone a push notification — the push contains no readable content, just "something arrived." That push wakes a tiny piece of Clave for about 30 seconds: it decrypts the request, checks the rules **you** set for that app, signs with the key in your Keychain, sends back an encrypted response, and goes back to sleep. The app gets its signature. The key never moved.

**What NIP-46 is** (for "what's NIP-46?" replies): the open Nostr standard for exactly this — apps requesting signatures from a separate signer instead of holding keys themselves. Clave implements it on iOS; Amber implements it on Android; they interoperate with any client that supports the standard. It's not a Clave-proprietary thing, and that's the point.

**Why iOS needed something new** (for "why not just do what Amber does?"): Amber leans on **NIP-55**, Android's app-to-app intent system, to pass signing requests between a client and the signer locally on-device. iOS has no equivalent — its URL-scheme hand-offs are unreliable and break in standalone PWA mode, and iOS aggressively suspends background apps, so a persistent-connection signer can't run the way Amber does. Clave's push-proxy + Notification Service Extension design exists to route around exactly those constraints. It's not that nobody tried on iOS — it's that the Android approach doesn't survive iOS's rules.

## Proof points (all verifiable, cite freely)

- **Open source, MIT licensed** — github.com/DocNR/clave. Anyone can read the signing path.
- **Open source and security-reviewed.** The full signing path is public and has had an internal security audit (2026-04-17, before external TestFlight) plus automated weekly drift-checks. An independent third-party audit is on the roadmap — it's expensive and depends on funding/time, so we don't claim it's happened until it has.
- **Proven in real-world use.** Months of daily signing across nine verified clients, not a fresh proof-of-concept.
- **The key never leaves the device.** iOS Keychain, this-device-only flag — not iCloud-synced, not in backups.
- **The server can't cheat.** The proxy never holds any key, can't decrypt requests (end-to-end NIP-44 encryption), and can't even register a push token for a pubkey it doesn't own (NIP-98 authenticated registration).
- **Per-app permissions.** Full/Medium/Low trust per client, per-event-kind overrides, sensitive actions (profile changes, contact list, deletions) require explicit approval. Activity log for everything. One-tap unpair.
- **Multi-account pairing.** Pair a client once and bring all your accounts in — one approval flow, one signer session per account. Clave introduced this as an open extension (`accounts=multi`), validated end-to-end with Jank (a full-featured Nostr client at https://jank.army), with a NIP draft planned so any signer or client can adopt it.
- **Works with the clients people actually use.** Verified: Nostur, fevela.me, Jank, Primal (web), Coracle, Jumble, noStrudel, zap.cooking, YakiHonne.
- **Honest interop tracking.** We publish a per-client compatibility matrix and classify every failure as signer-side, client-side, library-shared, or spec-ambiguity — including when the bug is ours.
- **We dogfood it:** the official Clave account is itself operated through Clave — the person posting has never seen its key. *(Post this only once the pairing in the social plan is actually set up.)*

## Honest caveats (volunteer must know these cold)

State these proactively — credibility is the asset:

- **It holds your real key — treat it like any app you'd trust with your nsec.** This is the honest framing, not "throwaway only" anymore: putting your key in Clave deserves the same consideration you'd give any signer or client you hand your nsec to. The argument in Clave's favor is the *trade-off* — Clave becomes the single place that holds your key, instead of the many copies you create by pasting your nsec into every client. Fewer attack surfaces, not zero. An independent third-party audit is still on the roadmap; until then, lead with "open source, internally audited, months of real-world use" and let people make an informed call. (New, cautious users pairing a throwaway key first is still a perfectly reasonable suggestion — just not a scolding requirement.)
- **Still TestFlight beta.** Not on the App Store yet. Say so plainly; don't imply 1.0 stability.
- **The proxy sees metadata.** It knows which pubkeys have registered devices and when an encrypted request arrived for them. It cannot read contents or sign anything — but "the server sees nothing" would be a false claim. Say "the server sees that a request arrived, never what's in it."
- **There is currently one proxy and one pinned relay for bunker pairing** (`relay.powr.build`). If it's down, push-wake signing is down. Self-hosting is possible but not yet fully documented; multi-relay support is backlogged.
- **Client support varies.** Nine clients are verified (list above), but per-client caveats exist — point people to `docs/nip46-compatibility.md` rather than promising "works with everything," and never vouch for a client that isn't on the list.
- **Same-device pairing on iOS: use the bunker code.** Pasting a client's nostrconnect URI into Clave on the same iPhone is unreliable for reasons outside any signer's control (iOS freezes the client's connection when backgrounded). Bunker flow avoids it entirely.

## Differentiation (compare without trash-talking)

| | Where the key lives | Trade-off to mention |
|---|---|---|
| **Clave** | iPhone Keychain, on your device | TestFlight beta (months of real-world use); depends on a push proxy you can self-host (docs coming); independent audit still on the roadmap |
| **Amber** | Android device | The same idea on the other platform — ally, not competitor. Amber uses Android's NIP-55 app-to-app intents; iOS has no equivalent, which is *why* Clave's push-based design exists. Be generous; the Amber comparison legitimizes Clave. |
| **nsec.app / web signers** | Browser storage | Works today, cross-platform; key sits in a browser context |
| **nsecBunker / hosted signers** | The operator's server | Convenient; different trust model — you trust the operator with the key |
| **Pasting nsec into clients** | Every app | The status quo Clave exists to end |

Frame: "different trust models for different people — here's where each puts your key." Never "X is insecure garbage." Other signer projects are allies in making NIP-46 the norm.

## Never say (binding)

- ❌ "Unhackable," "100% secure," "zero-knowledge," "trustless" — security absolutes are wrong and invite hostile attention.
- ❌ A flat "safe for your main key" *guarantee*. The honest framing is allowed and encouraged: "Clave holds your real key like any signer does — the win is one attack surface instead of many." State the trade-off; don't promise an outcome.
- ❌ "It's been independently audited" / "the audit proves it's safe" — an internal audit happened; a third-party one hasn't yet. Say "open source, internally audited, independent audit on the roadmap."
- ❌ "The server sees nothing" — it sees metadata; say what it can't see instead (contents, keys).
- ❌ "Fully decentralized" — there's currently one proxy and a pinned bunker relay. Say "self-hostable, end-to-end encrypted" instead.
- ❌ "Works with every Nostr client" — point to the compatibility matrix.
- ❌ Ship dates, feature promises, or "coming soon" for anything not already merged.
- ❌ Anything negative about a named client or signer project.
