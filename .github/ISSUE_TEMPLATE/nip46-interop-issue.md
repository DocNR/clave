---
name: NIP-46 interop issue
about: Report a NIP-46 compatibility issue between Clave and a Nostr client. The bug may be in Clave, the client, a shared library, or in spec ambiguity — we'll triage.
title: "NIP-46: <client name> — <one-line summary>"
labels: nip46-compat
assignees: ''
---

<!--
Thanks for filing! This template captures the info we need to triage a NIP-46 compatibility issue.
If a field doesn't apply, leave it blank or write "n/a" — partial reports are still useful.
Please check the existing matrix at docs/nip46-compatibility.md before filing to avoid duplicates.

A note on framing: this isn't a "broken client" report. It's an interop report. Where the bug
ultimately lives (Clave, client, shared library, or spec) is something we figure out together
after the report is filed. See the triage guide in docs/nip46-compatibility.md.
-->

## Client

- **Name:**
- **URL or app store link:**
- **Platform:** <!-- web / iOS / Android / desktop -->
- **Library (if known):** <!-- e.g. NDK, nostr-tools, welshman, applesauce-signers, custom -->

## Signer setup

- **Pairing method used:** <!-- Clave bunker:// / Clave nostrconnect:// / other signer -->
- **Clave build number:** <!-- Settings → tap the version row to reveal -->
- **Other signer tested (if any):** <!-- Amber, nsec.app, nsecBunker — helps narrow whether the bug is signer-specific -->

## What happened

### Expected
<!-- What should have happened? e.g. "Pairing should complete and I should see the client listed in Connected Clients" -->

### Actual
<!-- What actually happened? e.g. "Pairing UI in the client stalls forever. No errors in Clave's activity log." -->

## Reproducer

<!-- Step-by-step. Even rough notes help. -->

1.
2.
3.

## Evidence

<!-- Any of the following help triage:
- Screenshots
- Console errors (web clients: open devtools → Console)
- Relay logs if you have them
- Clave activity-log screenshots (Settings → Activity)
- Recent logs (Settings → 7-tap version row → Copy Recent Logs, then paste here)
-->

## Already triaged?

<!-- If you've already done some narrowing yourself, please mention it here. Examples:
- "Tried with two signers (Clave + Amber), both fail" → suggests client/library bug
- "Reproduced against Clave using Nip46Lab (https://github.com/greenart7c3/Nip46Lab)
  as a neutral reference client" → suggests Clave-side bug
See the triage guide in docs/nip46-compatibility.md. -->

---

_Before filing: please check [docs/nip46-compatibility.md](https://github.com/DocNR/clave/blob/main/docs/nip46-compatibility.md) to see whether this client is already documented as ⚠️ Partial or ❌ Broken with a known workaround._
