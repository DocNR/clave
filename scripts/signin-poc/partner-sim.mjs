// Fake partner client ("Conduit simulator") for the Sign in with Clave PoC.
// Proves, against the SHIPPED Clave app with zero iOS diffs:
//   1. handshake  — mints a nostrconnect URI, prints the Universal Link + QR,
//                   listens for the connect ack and validates the echoed secret
//                   (handles both the bare-string and accounts=multi JSON forms)
//   2. resume probe — after the ack, sends get_public_key with the session
//                   keypair and confirms it answers with NO approval prompt
//   3. lock-screen signing — sends a kind:1 sign_event; if it isn't
//                   auto-signed, approve it from the iOS notification banner
//                   WITHOUT opening Clave and watch the response arrive
//
// Run from a laptop (cross-device: the laptop's socket never freezes, so the
// happy path is isolated from the iOS backgrounding problem). The same-device
// variant is a later, separate harness.
//
// Usage:
//   npm install && node partner-sim.mjs [--relay wss://...]... [--perms sign_event:1]
//                  [--multi] [--no-sign] [--print-only] [--window 300]

import WebSocket from 'ws';
import qrcode from 'qrcode-terminal';
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from 'nostr-tools/pure';
import { bytesToHex, hexToBytes } from 'nostr-tools/utils';
import * as nip44 from 'nostr-tools/nip44';
import * as nip04 from 'nostr-tools/nip04';
import { randomBytes } from 'node:crypto';

// ---------- args ----------
const argv = process.argv.slice(2);
function flag(name) { return argv.includes(`--${name}`); }
function vals(name) {
  const out = [];
  for (let i = 0; i < argv.length; i++) if (argv[i] === `--${name}` && argv[i + 1]) out.push(argv[++i]);
  return out;
}
const RELAYS = vals('relay').length ? vals('relay') : ['wss://relay.powr.build'];
const PERMS = vals('perms')[0] || '';
const MULTI = flag('multi');
const NO_SIGN = flag('no-sign');
const PRINT_ONLY = flag('print-only');
const WINDOW_S = Number(vals('window')[0] || 300); // listen window; spec Phase-1 stash TTL is 10 min

// ---------- session identity (the partner's ephemeral client keypair) ----------
const clientSk = generateSecretKey();
const clientPk = getPublicKey(clientSk);
const secret = bytesToHex(randomBytes(8)); // 16 hex chars, matching clave.casa's shape

// Manual %-encoding: URLSearchParams would emit '+' for spaces, which Swift's
// URLComponents (Clave's parser) does NOT decode back to a space.
const kv = [];
for (const r of RELAYS) kv.push(['relay', r]);
kv.push(['secret', secret]);
if (PERMS) kv.push(['perms', PERMS]);
if (MULTI) kv.push(['accounts', 'multi']);
kv.push(['name', 'Signin PoC'], ['url', 'https://clave.casa']);
const query = kv.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
const ncUri = `nostrconnect://${clientPk}?${query}`;
const universalLink = `https://clave.casa/connect/?uri=${encodeURIComponent(ncUri)}`;

console.log('\n=== Sign in with Clave — partner simulator ===\n');
console.log('nostrconnect URI:\n  ' + ncUri + '\n');
console.log('Universal Link (tap on iPhone, or scan the QR with the Camera app):\n  ' + universalLink + '\n');
qrcode.generate(universalLink, { small: true });
if (PRINT_ONLY) process.exit(0);

// ---------- crypto helpers (mirror Clave: respond in the family you receive) ----------
function convKey(peerPk) { return nip44.v2.utils.getConversationKey(clientSk, peerPk); }
function encrypt44(peerPk, plaintext) { return nip44.v2.encrypt(plaintext, convKey(peerPk)); }
async function decryptAny(peerPk, content) {
  if (content.includes('?iv=')) return nip04.decrypt(bytesToHex(clientSk), peerPk, content);
  return nip44.v2.decrypt(content, convKey(peerPk));
}

// ---------- relay pool (minimal) ----------
const sockets = [];
function openSocket(url, onEvent) {
  return new Promise((resolve) => {
    const ws = new WebSocket(url, { handshakeTimeout: 10000 });
    ws.on('open', () => {
      ws.send(JSON.stringify(['REQ', 'signin', { kinds: [24133], '#p': [clientPk] }]));
      resolve(ws);
    });
    ws.on('message', (data) => {
      try {
        const m = JSON.parse(data.toString());
        if (m[0] === 'EVENT' && m[1] === 'signin') onEvent(m[2], url);
      } catch { /* ignore */ }
    });
    ws.on('error', (e) => { console.log(`  [${url}] socket error: ${e.message}`); resolve(null); });
    sockets.push(ws);
  });
}
function publishAll(ev) {
  const payload = JSON.stringify(['EVENT', ev]);
  for (const ws of sockets) if (ws && ws.readyState === WebSocket.OPEN) ws.send(payload);
}

// ---------- protocol state ----------
const t0 = Date.now();
const seen = new Set();
const accounts = []; // {signerPk, name, picture} — accumulate per integrations.md
let expectedTotal = null;
const pendingRpc = new Map(); // id -> {method, resolve, sentAt, notified}

function parseAckResult(result) {
  // integrations.md: bare echoed-secret string, or JSON {echoed_secret, name?, picture?, total}
  if (typeof result === 'string' && result.startsWith('{')) {
    try {
      const p = JSON.parse(result);
      return { echoed: p.echoed_secret, name: p.name, picture: p.picture, total: p.total };
    } catch { /* fall through */ }
  }
  return { echoed: result };
}

async function handleEvent(ev) {
  if (seen.has(ev.id)) return;
  seen.add(ev.id);
  if (!verifyEvent(ev)) return;
  let payload;
  try { payload = JSON.parse(await decryptAny(ev.pubkey, ev.content)); } catch { return; }

  // RPC response to something we sent
  if (payload.id && pendingRpc.has(payload.id)) {
    const rpc = pendingRpc.get(payload.id);
    if (payload.error) {
      // Clave's two-stage pattern: "permission denied" = approval pending, keep waiting
      if (/permission denied/i.test(payload.error) && !rpc.notified) {
        rpc.notified = true;
        console.log(`  [${rpc.method}] approval pending — long-press the Clave banner on the iPhone`
          + ' and tap Approve (do NOT open Clave: this is the lock-screen leg).');
        return;
      }
      pendingRpc.delete(payload.id);
      rpc.resolve({ error: payload.error, ms: Date.now() - rpc.sentAt });
      return;
    }
    pendingRpc.delete(payload.id);
    rpc.resolve({ result: payload.result, ms: Date.now() - rpc.sentAt });
    return;
  }

  // unsolicited: expect the connect ack
  if (payload.result !== undefined) {
    const { echoed, name, total } = parseAckResult(payload.result);
    if (echoed !== secret) return; // not our handshake
    if (total) expectedTotal = total;
    if (!accounts.some((a) => a.signerPk === ev.pubkey)) {
      accounts.push({ signerPk: ev.pubkey, name });
      console.log(`\n✓ connect ack #${accounts.length} at +${((Date.now() - t0) / 1000).toFixed(1)}s`
        + `  signer=${ev.pubkey.slice(0, 12)}…${name ? `  name="${name}"` : ''}`
        + (expectedTotal ? `  (${accounts.length}/${expectedTotal})` : ''));
    }
    if (!MULTI || (expectedTotal && accounts.length >= expectedTotal)) void runSessionChecks();
  }
}

function sendRpc(signerPk, method, rpcParams) {
  const id = bytesToHex(randomBytes(8));
  const ev = finalizeEvent({
    kind: 24133,
    created_at: Math.floor(Date.now() / 1000),
    tags: [['p', signerPk]],
    content: encrypt44(signerPk, JSON.stringify({ id, method, params: rpcParams })),
  }, clientSk);
  return new Promise((resolve) => {
    pendingRpc.set(id, { method, resolve, sentAt: Date.now(), notified: false });
    publishAll(ev);
    setTimeout(() => {
      if (pendingRpc.has(id)) { pendingRpc.delete(id); resolve({ timeout: true, ms: 120000 }); }
    }, 120000);
  });
}

let checksStarted = false;
async function runSessionChecks() {
  if (checksStarted) return;
  checksStarted = true;
  const { signerPk } = accounts[0];

  // --- resume probe: must answer with NO prompt (LightSigner always-allows get_public_key)
  console.log('\n→ resume probe: get_public_key (expect fast, promptless)…');
  const probe = await sendRpc(signerPk, 'get_public_key', []);
  if (probe.result) {
    console.log(`✓ probe answered in ${probe.ms}ms — user pubkey ${String(probe.result).slice(0, 12)}…`
      + (probe.ms > 5000 ? '  (slow: went through APNs+NSE — was Clave backgrounded? still a pass)' : ''));
  } else {
    console.log(`✗ probe FAILED: ${JSON.stringify(probe)} — if this prompted on the phone, the`
      + ' resume-probe design assumption is broken; file against the spec.');
  }

  // --- signing leg (lock-screen approve demo when not auto-signed)
  if (!NO_SIGN) {
    console.log('\n→ sign_event kind:1 (background the phone first to demo lock-screen approve)…');
    const draft = {
      kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [],
      content: 'Sign in with Clave PoC — this event is never published.',
    };
    const sign = await sendRpc(signerPk, 'sign_event', [JSON.stringify(draft)]);
    if (sign.result) {
      let ok = false;
      try { ok = verifyEvent(JSON.parse(sign.result)); } catch { /* ignore */ }
      console.log(ok
        ? `✓ signed + signature verified in ${(sign.ms / 1000).toFixed(1)}s — the event was NOT published anywhere`
        : `✗ signer returned an event that failed verification: ${String(sign.result).slice(0, 120)}`);
    } else {
      console.log(`✗ sign_event: ${JSON.stringify(sign)}`);
    }
  }

  console.log('\n=== PoC summary ===');
  console.log(`accounts paired: ${accounts.length}${expectedTotal ? `/${expectedTotal}` : ''}`);
  console.log(`ack latency: +${((Date.now() - t0) / 1000).toFixed(1)}s window (see per-ack lines above)`);
  console.log('Cleanup: unpair "Signin PoC" from the account\'s connected clients in Clave.');
  for (const ws of sockets) try { ws.close(); } catch { /* ignore */ }
  process.exit(0);
}

// ---------- go ----------
await Promise.all(RELAYS.map((r) => openSocket(r, handleEvent)));
console.log(`\nListening on ${RELAYS.join(', ')} for up to ${WINDOW_S}s — approve on the iPhone…`);
setTimeout(() => {
  if (!accounts.length) {
    console.log(`\n✗ no ack within ${WINDOW_S}s. Spec-conformant next step: retry-not-error`
      + ' (re-run; on same-device this is where the re-ack window will matter).');
    process.exit(1);
  } else void runSessionChecks();
}, WINDOW_S * 1000);
