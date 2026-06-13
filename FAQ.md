# Clave FAQ

Plain-language answers to the questions people ask most. For the technical deep-dive, see the [README](README.md); for the security model and how to report issues, see [SECURITY.md](SECURITY.md).

## The basics

**What is Clave?**
An iOS app that keeps your Nostr private key (your nsec) locked in your iPhone's Keychain. Other Nostr apps pair with it and ask it to sign things on your behalf — post a note, log in, decrypt a DM — but they never receive the key itself. In Nostr terms, it's a NIP-46 "remote signer."

**Why would I want that?**
Your Nostr key is your identity, and unlike a password it can't be rotated — if it leaks, that identity is gone for good. The common habit is pasting your nsec into every app you try, which leaves a copy of that irreplaceable secret in each one. Clave replaces that with a single place that holds your key; your apps connect to it instead of each keeping their own copy. Fewer places your key lives means fewer ways it can leak.

**What's NIP-46?**
The open Nostr standard for exactly this: apps request signatures from a separate signer rather than holding your key themselves. Clave implements it on iOS, [Amber](https://github.com/greenart7c3/Amber) implements it on Android, and various web signers implement it too — they all interoperate with any client that supports the standard.

## Security & privacy

**Where is my key stored? Does it ever leave my phone?**
It's stored in the iOS Keychain with a this-device-only flag — not synced to iCloud, not included in device backups. It never leaves your device.

**Does Clave's server see my key or my messages?**
No. Clave uses a small push proxy whose only job is to notice that an encrypted request arrived for you and send your phone a wake-up notification. That notification carries no readable content. The proxy never holds any key, can't decrypt your requests (they're end-to-end encrypted), and can't sign anything as you.

**Then why does it need a server at all? Doesn't that make it centralized?**
iOS aggressively suspends background apps, so a signer needs *something* to wake it when a request arrives — and Apple's push system is the only reliable mechanism, which requires a small relay-watching server. It's designed to know as little as possible (that an encrypted request arrived, never what's in it), the code is open source, and you can run your own proxy. We'd rather be upfront about that trade-off than pretend it isn't there.

**What data does Clave collect?**
The proxy stores which pubkeys have a registered device token and sees when an encrypted request arrives for one. It can't read request contents and holds no keys. There are no analytics or trackers in the app. The full security model is in the [README](README.md#security-model).

**Is it open source? Has it been audited?**
Yes — open source under the MIT license, so anyone can read the signing path. It's had an internal security audit and runs automated weekly checks, and it's been in real-world use for months. An independent third-party audit is on the roadmap; it depends on funding and time, so we won't claim it's done until it is.

**Can I use my main key, or should I use a throwaway?**
Use whichever you're comfortable with. The honest way to think about it: trusting Clave with your key deserves the same consideration as any app you'd hand your nsec to — the difference is that Clave becomes the *one* place holding it, instead of every client you've ever pasted it into. It's still in TestFlight beta and the independent audit is still ahead of us, so go in informed. If you're cautious, starting with a secondary key is a perfectly reasonable way to try it.

**How do I report a security problem?**
Privately, please — not via a public GitHub issue. See [SECURITY.md](SECURITY.md) for the contacts (Nostr DM or email).

## Using Clave

**Which Nostr clients work with Clave?**
Verified working today: Nostur, Primal (web), Coracle, Jumble, noStrudel, Jank, fevela.me, zap.cooking, and YakiHonne. Others may work too — the live, honest compatibility matrix (including known per-client quirks) is at [docs/nip46-compatibility.md](docs/nip46-compatibility.md). If you try a client that isn't listed, tell us what happens.

**Pairing isn't working — what should I check?**
Two common fixes: (1) If the client app and Clave are on the *same* iPhone, pair using Clave's **bunker code** (Connect → copy or scan the QR) rather than pasting the client's URI into Clave — same-device pairing the other direction is unreliable on iOS for reasons no signer can fully fix. (2) Make sure notifications are enabled for Clave. If it's still stuck, [open an issue](https://github.com/DocNR/clave/issues) with the client name and what you saw.

**Can I use more than one account?**
Yes. Clave holds multiple keys and lets you switch between them. With clients that support our multi-account pairing — [Jank](https://jank.army) today — you pair once and sign in with all your accounts in a single flow; with other clients you pair each account separately. Either way, every key stays on your phone.

**Why is it iOS only? Is there an Android version?**
Android already has an excellent signer — Amber. Clave exists because iOS didn't have an equivalent: Amber relies on Android's NIP-55 app-to-app intents, which iOS has no equivalent for, and iOS suspends background apps, so a different approach (push-woken signing) was needed. We're focused on doing the iOS side well.

**How is Clave different from Amber, nsec.app, or nsecBunker?**
They're all NIP-46 signers with different trade-offs about where your key lives: Amber keeps it on your Android device (Clave is the iOS counterpart), web signers like nsec.app keep it in your browser, and hosted signers like nsecBunker keep it on a server you trust. Clave keeps it in your iPhone's Keychain. Different models for different people — and they're allies in making "don't paste your nsec everywhere" the norm.

**How much does it cost?**
Clave is free and open source (MIT licensed).

**How do I report a bug or request a feature?**
Open an issue at [github.com/DocNR/clave/issues](https://github.com/DocNR/clave/issues). For NIP-46 interop problems with a specific client, there's a dedicated [interop issue template](https://github.com/DocNR/clave/issues/new?template=nip46-interop-issue.md).
