# Clave official account — volunteer playbook

_This is your operating manual for the official Clave account. It's written so you never need to guess: if a situation isn't covered here, that's a signal to escalate, not improvise. Read [talking-points.md](talking-points.md) alongside this — especially its "Never say" list, which is binding._

## Your access

You post through Clave itself: your client is paired to the official account's signer, with permissions set by the maintainer. You can publish notes and replies. You **cannot** see the account's private key, change its profile, edit its follow list, or delete events — those route to the maintainer for approval. Everything you sign appears in an activity log.

If your own phone or client is ever lost or compromised, tell the maintainer immediately — your pairing gets revoked in one tap and the account is unaffected. This is not a "you're in trouble" event; it's the system working.

## Voice

- **Plain language.** If your non-Nostr friend wouldn't understand the post, rewrite it. "Apps ask for signatures, they never get the key" beats any sentence containing "NIP-46 RPC."
- **Honest, including about weaknesses.** Beta status, the metadata the server sees, clients that don't work yet — we say these things first, before anyone else does. Credibility is the whole brand.
- **Warm to everyone, combative with no one.** Zap and boost good community answers. Never dunk on critics, competitors, or confused users.
- **No hype-speak.** No "revolutionary," no rocket emojis on security claims, no countdown posts.

## What you can post: green / yellow / red

### 🟢 Green — post on your own judgment

- Anything from the ready-to-post library below, lightly adapted
- Education posts built from talking-points.md (key hygiene, the notary analogy, "what is a remote signer")
- Boosts/zaps of community posts about Clave, Amber, NIP-46, key safety
- Replies using the FAQ templates below
- Polls about preferences ("which client should we test next?")
- Thank-yous to testers and client developers

### 🟡 Yellow — draft it, get maintainer approval before posting

- Any claim about a specific client working or not working (the matrix changes; your info may be stale)
- Release/update announcements (maintainer supplies the facts; you make them readable)
- Replies to threads with significant reach or from prominent accounts
- Anything responding to criticism of Clave's architecture or security
- Long-form posts/threads you wrote yourself
- Cross-posting someone else's technical claims about Clave

### 🔴 Red — never post; escalate immediately

- Anything about security vulnerabilities, real or claimed (see escalation section — this is the big one)
- Ship dates, roadmaps, feature promises, App Store timing
- Security guarantees beyond the approved talking points
- Negative statements about any named project or person
- Legal, regulatory, or App-Store-policy topics
- Requests for users' keys, in any form, ever — and never ask users to post screenshots that might contain a key or bunker code

## Replying to common questions

Use these as written or lightly adapted. Where a template says **[escalate]**, send the thread to the maintainer instead of continuing.

**"What is Clave?"**
> Clave keeps your Nostr key locked in your iPhone's Keychain. Apps you pair with it can ask for signatures — post a note, log in, decrypt a DM — but they never get the key itself. Open source: github.com/DocNR/clave

**"Is my key on your server?"**
> No — your key never leaves your iPhone's Keychain. Our server's only job is to send your phone a wake-up push when a signing request arrives. The push contains no readable content, and the server can't decrypt requests or sign anything, because it never has any key.

**"Why does it need a server / push notifications at all? Doesn't that make it centralized?"**
> Fair question. iOS suspends background apps, so a signer needs *something* to wake it — Apple's push system is the only reliable mechanism, and that requires a small relay-watching server. It's designed to know as little as possible: it sees that an encrypted request arrived for you, never what's inside. The code is open source and you can run your own. We'd rather be honest about that trade-off than pretend it isn't there.

**"How is this different from Amber?"**
> Same idea, different platform: Amber is the Android signer, Clave is the iOS one. We think Amber is great — both apps implement the same open standard (NIP-46), so clients that support one generally support the other.

**"Does it work with [client X]?"**
> If the client is on the verified list — **Nostur, fevela.me, Spectr, Primal (web), Coracle, Jumble, noStrudel, zap.cooking, YakiHonne**: "Yes — verified working."
> Anything else: "Best place to check is our live compatibility matrix: github.com/DocNR/clave/blob/main/docs/nip46-compatibility.md — and if you try it, tell us what happens, that's exactly the testing we need."
> Never promise an unlisted client works.

**"Can I use multiple accounts?"**
> Yes — Clave supports multiple accounts, and with clients that support our multi-account pairing (Spectr today), you pair once and sign in with all your accounts in a single flow. With other clients, you pair each account separately. Either way, every key stays on your phone.

**"It's not working / pairing fails / requests time out."**
> Sorry about that — two quick things to try: (1) if the app and Clave are on the same iPhone, pair using Clave's bunker code rather than the app's QR/URI — same-device pairing the other way is unreliable on iOS, not just for us. (2) Make sure notifications are enabled for Clave. If it's still stuck, would you open an issue here so we can dig in? github.com/DocNR/clave/issues — include the client name and what you saw.
>
> If they report back that it still fails, or the question gets technical: **[escalate]**.

**"Is it safe? Has it been audited?"**
> It's open source (MIT) and had a full security audit before the public beta, with ongoing automated checks. That said — it's a **beta**, which is why we ask testers to use a throwaway key, not their main one. We'd rather under-promise here.

**"When is it on the App Store?" / "When will feature X ship?"**
> No date to announce — it's on TestFlight while we work through the beta. Follow here and you'll see it the moment that changes.
> (Never speculate, even casually, even in DMs.)

**"Why iOS only? Android version?"**
> Android already has a great signer — Amber. Clave exists because iOS didn't have an equivalent: iOS's background restrictions needed a different architecture (push-based wake-up). One platform, done well.

**"Can I use my real/main nsec?"**
> Please don't yet — Clave is in beta, and we ask all testers to use a throwaway key. When we're confident enough to change that advice, it'll be announced clearly.

**"What data do you collect?"**
> The proxy stores which pubkeys have a registered device token, and sees when an encrypted request arrives for one. It can't read request contents (end-to-end encrypted) and holds no keys. There are no analytics or trackers in the app. The full security model is public: github.com/DocNR/clave#security-model

**"This architecture is flawed because…" (technical criticism)**
> Genuinely interested in this — would you open an issue so the right people see it? github.com/DocNR/clave/issues
> Then **[escalate]**. Don't debate architecture, even if you think you know the answer.

**Trolling / bad faith / "all signers are scams":**
> One factual, friendly reply maximum, then disengage. Never delete-and-block without checking with the maintainer first. If it gets personal or persistent: **[escalate]**.

## 🚨 Security reports — the one rule that matters most

If anyone — public reply, DM, vague hint — claims to have found a security problem, a way to steal keys, a way to forge signatures, *anything* in that family:

1. **Do not discuss it publicly. Do not ask for details. Do not confirm or deny anything.**
2. Reply (or DM back) exactly this:
   > Thank you for flagging this — security reports get priority handling through a private channel so they're fixed before details are public. Please use the contacts in github.com/DocNR/clave/blob/main/SECURITY.md (Nostr DM or email). The maintainer responds within 3 days.
3. **Immediately** forward the thread/DM to the maintainer, even if it looks like nonsense. Maintainer decides what's real.

This applies even if the person is posting details publicly already. You never add commentary — your only public move is the redirect above.

## Escalation quick reference

| Situation | Action |
|---|---|
| Security claim of any kind | Template above + forward to maintainer **immediately** |
| Bug report you can't resolve with the FAQ | Point to GitHub issues, forward thread to maintainer |
| Press, podcast, partnership, or business inquiry | "Passing this to the maintainer — expect a reply soon" + forward |
| Question not covered in this doc | Don't improvise — ask maintainer, reply after |
| Prominent account engaging (positive or negative) | Forward before replying |
| You posted something wrong | Tell maintainer first, then correct publicly with a plain "correction:" note. Mistakes are fine; cover-ups are not. |

Maintainer contact: _(fill in: Nostr npub + a faster back-channel, e.g. Signal/SimpleX)_. Expected response time: _(fill in)_. If unreachable and the situation is in the red zone: post nothing. Silence is always safe; a wrong official statement is not.

## Ready-to-post library

Use as-is or lightly adapted. Recruitment posts (marked ⚠️) must keep the throwaway-key line word-for-word.

1. > Your Nostr key isn't a password. Passwords get reset; your nsec can't be. Every app you paste it into is another copy of the one secret you can never change. That's the problem remote signers exist to fix.

2. > Think of Clave as a notary living in your iPhone. Apps bring documents to be stamped — the notary checks who's asking, stamps it, hands it back. Nobody ever borrows the stamp. 🔏

3. ⚠️ > Clave is in open beta on TestFlight — an iOS signer that keeps your Nostr key in the Keychain while your apps sign through it. **It's beta: please use a throwaway key, not your main nsec.** Link in profile.

4. > "Doesn't the push server see my stuff?" It sees that an encrypted request arrived for you. It can't read it, can't sign anything, never touches a key. We'd rather explain the trade-off than pretend there isn't one. Full security model is public: github.com/DocNR/clave#security-model

5. > Android has had this for years: Amber holds your key, every app signs through it. Clave is that, for iOS — built on push notifications because iOS kills background apps. Same open standard (NIP-46), so the ecosystem works across both.

6. > Pairing tip: if your Nostr app and Clave are on the same iPhone, use Clave's bunker code (Connect → copy/QR) instead of pasting the app's URI into Clave. Same-device pairing the other direction fights iOS itself — bunker flow sidesteps it.

7. > You decide what each app is allowed to do. Posting notes? Fine. Changing your profile, editing your follow list, deleting events? Those need your explicit tap, every time. Per-app permissions + an activity log of every request.

8. > Fun fact: this account runs on Clave. The person typing this has never seen its private key — their client is paired with permission to post, and nothing else. That's the product.
   _(⚠️ Only after the maintainer confirms the pairing is actually set up this way.)_

9. > We publish an honest compatibility matrix for every client we test — including when the bug is on our side. Signer-side, client-side, library bug, or spec ambiguity: we say which. github.com/DocNR/clave/blob/main/docs/nip46-compatibility.md

10. > What's NIP-46, in one breath: an open standard where apps ask a separate signer for signatures instead of holding your key themselves. Clave on iOS, Amber on Android, others in browsers — one standard, your key in one place.

11. > Open source, MIT, audited before public beta, weekly automated security checks. Not because that makes it perfect — because you shouldn't have to take our word for any of this. github.com/DocNR/clave

12. ⚠️ > Testers wanted: Clave is verified working with Nostur, Primal (web), Coracle, Jumble, noStrudel, Spectr, fevela.me, zap.cooking, and YakiHonne. Pick your favorite, pair it, try to break it, tell us. **Beta — throwaway key only, please.**

13. > One pairing, all your accounts. Clave's multi-account flow lets you connect a client once and sign in with every identity you run — work npub, personal npub, project npub — each key separate, none of them ever leaving your phone. Live today in Spectr.

## ⏸️ On hold — do not post until the maintainer explicitly says go

The "throwaway key only" guidance is expected to soften as the beta matures. When (and only when) the maintainer gives the go-ahead, this is the transition announcement — until then, every caveat in this playbook stays exactly as written:

> Update on key guidance: since launch we've asked beta testers to use a throwaway key. As of build ___, with [audit/milestone — maintainer fills in], we're comfortable saying Clave is ready for daily-driver use. If you've been waiting to bring your main npub — this is the post. As always: your key never leaves your phone, and the code is open for anyone to verify. github.com/DocNR/clave

After it's posted, the maintainer will tell you which FAQ replies and library posts to update — don't edit them yourself.

## Weekly rhythm (suggested)

- **Mon:** education post (pillar content from talking points)
- **Wed:** product/how-to or community shout-out
- **Fri:** lighter post — poll, dogfood note, boost of ecosystem content
- **Daily, ~15 min:** scan mentions/replies, answer from FAQ, forward anything yellow/red
- **Weekly:** short note to maintainer — what people asked, what confused them, what's resonating. Confused-user questions are product feedback; that loop is half the value of this role.
