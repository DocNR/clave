# Security Policy

Clave holds your Nostr private key. A security issue here is especially serious — please report responsibly.

## Reporting a vulnerability

**Do not open a public GitHub issue for security problems.**

Contact the maintainer privately:

- **Nostr DM** (NIP-17 gift wrap preferred): `npub1xy54p83r6wnpyhs52xjeztd7qyyeu9ghymz8v66yu8kt3jzx75rqhf3urc`
- **Email:** thehypoxicdrive@gmail.com

Please include:

- A description of the issue and its impact
- Steps to reproduce (or a proof-of-concept)
- The Clave build number (Settings → About) and iOS version
- Whether you've disclosed the issue to anyone else

## Response

- Acknowledgment: within 3 days
- Triage + severity assessment: within 7 days
- Fix target depends on severity — out-of-band patch for Critical / High, next scheduled release for Medium, tracked in the public backlog for Low.

## Scope

**In scope:**

- The Clave iOS app (main target + Notification Service Extension)
- The relay-proxy (Node.js push proxy)
- Cryptographic implementations in `Shared/` — NIP-44 v2, NIP-04, BIP-340 Schnorr, HKDF, HMAC
- Key handling paths — Keychain attributes, pasteboard flags, backgrounding snapshots, export flow
- NIP-46 protocol logic — permission checks, bunker secret rotation, request dispatch, nostrconnect handshake
- NIP-98 server-side verification in the proxy

**Out of scope:**

- iOS kernel attacks, sandbox escapes, or XNU vulnerabilities
- Apple's build chain, code signing infrastructure, or App Store review process
- Hardware attacks (Secure Enclave bypass, JTAG, physical side channels)
- Jailbroken-device threat models (documented trade-off, not defended against)
- Social engineering attacks outside the app
- Physical access to an unlocked device
- Apple Push Notification Service, Cloudflare, or npm registry compromise

## Testing

Do **NOT** run exploitation attempts against the production proxy at `proxy.clave.casa` or against `relay.powr.build`. Run your proof-of-concept against a local instance (`node proxy.js` with your own `.env`) or use the test harness in `relay-proxy/test/`.

## Disclosure

Once a fix has shipped and been available to users for a reasonable window, the issue can be disclosed publicly — by writeup in this repo's `security-audits/` directory or by the reporter, at their preference. Credit is given unless the reporter requests anonymity.

## Prior audits

The codebase underwent a full security audit on 2026-04-17 before external TestFlight. Ongoing security maintenance includes an automated weekly drift-check and a planned quarterly full re-audit. Audit reports are maintained in a companion workspace and will be published to `security-audits/` in this repo.
