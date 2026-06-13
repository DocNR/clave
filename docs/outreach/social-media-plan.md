# Clave social media & outreach plan

_Audience: maintainer. Companion docs: [talking-points.md](talking-points.md) (message reference for anyone posting) and [volunteer-playbook.md](volunteer-playbook.md) (the doc you hand to the volunteer)._

## Goals (beta phase)

In priority order:

1. **Grow the TestFlight beta** with the right testers — people who understand the trade-off (one signer holding your key beats N clients holding copies) and will file useful reports.
2. **Educate on NIP-46 / key hygiene** so the market for a signer exists. Most Nostr users still paste their nsec into clients; they don't know there's a problem to solve.
3. **Recruit client developers** — every row added to `docs/nip46-compatibility.md` is worth more than a hundred likes. The `accounts=multi` extension also needs client adoption before the NIP draft.
4. **Build trust in the security posture** by being radically honest: open source, internally audited (independent third-party audit on the roadmap), in real-world use for months, still TestFlight beta — and the proxy's metadata visibility stated plainly.

Explicit non-goal right now: mass-market growth. Clave is still beta and pinned to one relay for bunker flow; chasing a viral spike of non-technical users before the App Store release and the third-party audit would outrun what the infrastructure and support can absorb.

Note on key guidance: the messaging across these docs has moved off the old "throwaway key only" rule to an **informed-choice framing** — Clave holds your real key like any signer does, and the win is one attack surface instead of many. Recruitment posts still name the honest caveats (beta, independent audit pending); they just no longer scold testers into a throwaway key.

## Channels

| Channel | Role | Who runs it |
|---|---|---|
| **Nostr (brand npub)** | Primary. The audience is literally Nostr users, and posting from a Clave-secured account is the product demo. ✅ npub exists | Volunteer (day-to-day), maintainer (releases, technical threads) |
| **X/Twitter** | Reach beyond Nostr — bitcoin/privacy crowd, iOS devs. Cross-post the best 2–3 Nostr posts per week. ⚠️ No account yet — create when bandwidth allows; Nostr comes first | Volunteer |
| **GitHub** (releases, Discussions) | Developer channel. Release notes, interop changelog, `accounts=multi` spec discussion. | Maintainer only |
| **Stacker News / r/nostr** | Occasional long-form: launch-style posts, architecture write-ups. Once or twice a month max. | Maintainer drafts, volunteer can repost |
| **Nostr dev group chats** (Telegram/SimpleX) | Interop coordination with client devs. Technical, relationship-driven. | Maintainer only |

### Run the brand account through Clave itself

Strongly recommended — this is both the best guardrail and the best marketing story:

1. Create a dedicated **brand npub** (not your personal npub, never the volunteer's key). You hold the nsec in your own Clave install.
2. The volunteer pairs their Nostr client to your Clave via `bunker://` with **Medium trust**.
3. Result: the volunteer can post kind-1 notes and replies, but **never sees the key**, can't change the profile (kind 0), can't touch the contact list (kind 3), can't delete events (kind 5) — those are protected kinds that ping you for approval. You get a full audit trail in the activity log, and you can unpair them in one tap if anything goes wrong.

That arrangement *is* the pitch: "our community manager posts from the official account daily and has never seen its private key." Post about it.

(Practical caveat: while bunker flow is pinned to `wss://relay.powr.build`, the volunteer's client needs to support bunker pairing — Nostur is verified. Test the pairing yourselves before handing it over.)

## Cadence & content mix

Realistic for one part-time volunteer: **3–5 Nostr posts/week**, 2–3 cross-posted to X, plus reply engagement. Don't over-commit; a steady drip beats a two-week burst followed by silence.

| Pillar | Share | Examples |
|---|---|---|
| **Education** (NIP-46, key hygiene, "why signers") | ~40% | "Your nsec can't be rotated like a password" series; plain-language NIP-46 explainers; the notary analogy |
| **Product** (features, releases, how-tos) | ~25% | Pairing demo videos (Nostur, fevela.me), release highlights, permission-model walkthroughs, multi-account picker demo |
| **Community & interop** | ~20% | New verified clients, shout-outs to client devs who fix NIP-46 bugs, compatibility-matrix updates, calls for testers of specific clients |
| **Engagement** | ~15% | Replies, zapping good answers, boosting ecosystem content (Amber, NIP discussions), polls ("which client should we verify next?") |

Rule of thumb: education and community posts can run on the volunteer's own judgment from the playbook; product claims and anything technical get maintainer review first (the playbook's green/yellow/red matrix covers this).

## First 30 days

Already in place: brand npub, public TestFlight invite link, clave.casa as the link-in-bio destination. Still needed: the volunteer's Clave pairing, an X account (optional, later), and a docs refresh (below).

**Week 0 prerequisite — refresh the public docs outreach points to.** The README's verified list ("Nostur, fevela.me") and the compatibility matrix (statuses from build ~29; app is at build 99) undersell the current state — nine clients are verified, multi-account has shipped. Posts will link to these docs; they need to agree with the posts before the recruitment push.

**Week 1 — foundation.** Set up the volunteer's Clave pairing to the brand npub (the dogfood story above). Publish a pinned "what is Clave" thread (talking-points doc has the copy). Volunteer practices with 2–3 education posts.

**Week 2 — beta recruitment.** TestFlight call-to-action posts — each one carries the honest caveats (still beta, independent audit on the roadmap) in the informed-choice framing, not a throwaway-key scold. Lead with the breadth of the verified-client list (nine clients people actually use). Short screen recording of bunker pairing → first signed note.

**Week 3 — multi-account.** Headline campaign: "one pairing, all your accounts." Demo video of the multi-account picker with Jank (jank.army); consumer posts from the library; maintainer publishes the `accounts=multi` write-up for devs (Stacker News or GitHub Discussion) and the volunteer amplifies.

**Week 4 — education series + dev outreach.** "Key hygiene week": one post per day on a single idea (key in N apps = N attack surfaces; keys can't rotate; what a remote signer is; what the proxy can and can't see; how to check per-client permissions). Close with the interop-issue call: "found a client that doesn't pair? Tell us, we triage signer-side vs client-side honestly" — the four-bucket triage taxonomy is genuinely differentiating; most projects blame the other side, you publish the analysis.

After day 30: settle into the steady cadence, one campaign per month (next candidates: per-client demo series, NIP-draft filing for `accounts=multi`, the independent third-party audit announcement when it completes, self-hosting story when `docs/SELF-HOSTING.md` lands).

## What success looks like

Track monthly, keep it lightweight:

- TestFlight tester count and weekly-active signers (proxy `/health` gives unique_pubkeys)
- Verified rows in the compatibility matrix (the single best metric)
- GitHub: stars, interop issues filed by outsiders, first-time contributors
- Nostr: follower count on brand npub, zaps/replies per post (vanity-adjacent, weight it least)

## Risks this plan manages

- **Beta over-promotion** → recruitment posts carry the honest caveats (still beta, independent audit on the roadmap) in informed-choice framing; growth is deliberately paced ahead of the App Store release.
- **Security-claim inflation** → the talking-points doc has an explicit "never say" list (including: never imply the independent third-party audit has happened, never give a flat "safe for your main key" guarantee); volunteer escalates all security questions beyond the approved FAQ.
- **Vulnerability reports arriving via social DMs** → playbook has a verbatim redirect-to-SECURITY.md template; volunteer never discusses publicly.
- **Volunteer account compromise** → volunteer never holds the brand key (Clave pairing model); blast radius is unpair-and-done.
