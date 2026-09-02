// Week-1 gate #1 for the Sign in with Clave spec:
// does a relay store kind:24133 (NIP-46 RPC, ephemeral range) so a client
// could recover a missed connect ack with a since-filter — or is it
// forward-only, meaning the re-ack window / resume probe must carry recovery?
//
// Method, per relay:
//   1. open sub LIVE (kinds:[24133], #p:[target]) BEFORE publishing
//   2. publish a throwaway-signed kind:24133 (and a kind:1 control)
//   3. record OK acceptance + live forwarding
//   4. fresh connection, sub REPLAY with since = created_at - 60
//   5. stored iff the event comes back before EOSE
// The kind:1 control distinguishes "24133 is ephemeral" from "this relay
// doesn't serve since-queries / rejects unknown pubkeys at all".

import WebSocket from 'ws';
import { generateSecretKey, getPublicKey, finalizeEvent } from 'nostr-tools/pure';

// Optional corporate-proxy support: only used when HTTPS_PROXY is set AND
// https-proxy-agent happens to be installed (it is not a dependency here).
const PROXY = process.env.HTTPS_PROXY || process.env.https_proxy;
let agent;
if (PROXY) {
  try {
    const { HttpsProxyAgent } = await import('https-proxy-agent');
    agent = new HttpsProxyAgent(PROXY);
  } catch { /* run direct */ }
}

const RELAYS = process.argv.slice(2).length
  ? process.argv.slice(2)
  : ['wss://relay.powr.build', 'wss://relay.damus.io', 'wss://relay.nsec.app'];

const sk = generateSecretKey();
const pk = getPublicKey(sk);
const targetPk = getPublicKey(generateSecretKey()); // throwaway "client" pubkey

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { agent, handshakeTimeout: 15000 });
    const timer = setTimeout(() => { ws.terminate(); reject(new Error('connect timeout')); }, 15000);
    ws.on('open', () => { clearTimeout(timer); resolve(ws); });
    ws.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

function send(ws, msg) { ws.send(JSON.stringify(msg)); }

// Collect relay messages until pred says stop (or timeout).
function collect(ws, ms, pred) {
  return new Promise((resolve) => {
    const got = [];
    const timer = setTimeout(() => { cleanup(); resolve(got); }, ms);
    function onMsg(data) {
      try {
        const m = JSON.parse(data.toString());
        got.push(m);
        if (pred && pred(m)) { cleanup(); resolve(got); }
      } catch { /* ignore non-JSON */ }
    }
    function cleanup() { clearTimeout(timer); ws.off('message', onMsg); }
    ws.on('message', onMsg);
  });
}

async function probeRelay(url) {
  const out = { relay: url };
  const now = Math.floor(Date.now() / 1000);

  const ev24133 = finalizeEvent({
    kind: 24133,
    created_at: now,
    tags: [['p', targetPk]],
    content: 'clave-signin-poc-ephemeral-probe', // not a real RPC; content is opaque to relays
  }, sk);
  const ev1 = finalizeEvent({
    kind: 1,
    created_at: now,
    tags: [],
    content: 'clave signin PoC storage control — ignore',
  }, sk);

  // --- connection 1: live sub, then publish both events
  let ws;
  try { ws = await connect(url); } catch (e) { out.error = `connect: ${e.message}`; return out; }
  send(ws, ['REQ', 'live', { kinds: [24133], '#p': [targetPk] }]);
  await collect(ws, 1500, (m) => m[0] === 'EOSE' && m[1] === 'live');

  const wait = collect(ws, 6000, (m) =>
    (m[0] === 'OK' && m[1] === ev1.id) || // kind:1 OK arrives last of the two publishes
    false);
  send(ws, ['EVENT', ev24133]);
  send(ws, ['EVENT', ev1]);
  const msgs = await wait;
  const ok24133 = msgs.find((m) => m[0] === 'OK' && m[1] === ev24133.id);
  const ok1 = msgs.find((m) => m[0] === 'OK' && m[1] === ev1.id);
  out.accepted24133 = ok24133 ? ok24133[2] : 'no OK received';
  out.okMsg24133 = ok24133 ? (ok24133[3] || '') : '';
  out.accepted1 = ok1 ? ok1[2] : 'no OK received';
  out.okMsg1 = ok1 ? (ok1[3] || '') : '';
  out.liveForwarded24133 = msgs.some((m) => m[0] === 'EVENT' && m[1] === 'live' && m[2]?.id === ev24133.id);
  ws.close();

  // --- connection 2: since-replay for both kinds
  await new Promise((r) => setTimeout(r, 1500)); // let writes settle
  let ws2;
  try { ws2 = await connect(url); } catch (e) { out.error = `reconnect: ${e.message}`; return out; }
  send(ws2, ['REQ', 'replay24133', { kinds: [24133], '#p': [targetPk], since: now - 60 }]);
  send(ws2, ['REQ', 'replay1', { kinds: [1], authors: [pk], since: now - 60 }]);
  let eose = 0;
  const replay = await collect(ws2, 8000, (m) => m[0] === 'EOSE' && ++eose >= 2);
  out.stored24133 = replay.some((m) => m[0] === 'EVENT' && m[1] === 'replay24133' && m[2]?.id === ev24133.id);
  out.stored1 = replay.some((m) => m[0] === 'EVENT' && m[1] === 'replay1' && m[2]?.id === ev1.id);
  ws2.close();
  return out;
}

for (const url of RELAYS) {
  const r = await probeRelay(url);
  console.log(JSON.stringify(r, null, 2));
}
