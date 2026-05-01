const WebSocket = require("ws");
const http = require("http");
const http2 = require("http2");
const crypto = require("crypto");
const fs = require("fs");

// --- Configuration (set via env vars) ---
const RELAY_URL = process.env.RELAY_URL || "wss://relay.powr.build";
const APNS_KEY_PATH = process.env.APNS_KEY_PATH || "./AuthKey.p8";
const APNS_KEY_ID = process.env.APNS_KEY_ID;
const APNS_TEAM_ID = process.env.APNS_TEAM_ID;
const APNS_TOPIC = "dev.nostr.Clave";
const APNS_HOST = process.env.APNS_HOST || "api.push.apple.com";
const TOKEN_FILE = "./tokens.json";
const HTTP_PORT = process.env.PORT || 3000;
const MAX_BODY_SIZE = 1024; // 1KB limit for registration requests

if (!APNS_KEY_ID || !APNS_TEAM_ID) {
  console.error("APNS_KEY_ID and APNS_TEAM_ID env vars required");
  process.exit(1);
}

const PING_INTERVAL = 30000; // 30 seconds
const PONG_TIMEOUT = 10000; // 10 seconds to respond

// --- NIP-98 auth + multi-signer storage ---
const { parseAuthHeader, verifyNip98, sha256Hex } = require("./nip98");
const { createStorage } = require("./storage");
const { createClientsStorage } = require("./clients");
const { createRelayPool } = require("./relayPool");
const { createApnsClient, shouldPruneToken, parseReason } = require("./apnsClient");

const PUBLIC_PRIMARY_URL = process.env.PUBLIC_RELAY_URL || "wss://relay.powr.build";

const storage = createStorage(TOKEN_FILE);
const CLIENTS_FILE = "./clients.json";
const clientsStorage = createClientsStorage(CLIENTS_FILE);
let relayPool = null; // initialized in server.listen after all deps are in scope
const migrationResult = storage.migrateIfLegacy();
if (migrationResult.migrated) {
  console.log(
    `[Storage] Migrated legacy tokens.json — backed up ${migrationResult.legacyCount} entries to .legacy-backup and wiped active storage. All testers must re-register.`
  );
}

// Dedupe by event id to guard against relay-level duplicate delivery.
// TTL is deliberately short; distinct events (even in rapid bursts from the
// same signer) must all reach the device — that's the whole point of push.
const SEEN_EVENT_TTL_MS = 60 * 1000;
const seenEvents = new Map();

function alreadySeen(eventId) {
  const now = Date.now();
  for (const [k, exp] of seenEvents) {
    if (exp < now) seenEvents.delete(k);
  }
  if (seenEvents.has(eventId)) return true;
  seenEvents.set(eventId, now + SEEN_EVENT_TTL_MS);
  return false;
}

// --- APNs client (HTTP/2 with GOAWAY-aware reconnection, see apnsClient.js) ---
const apnsClient = createApnsClient({
  host: APNS_HOST,
  topic: APNS_TOPIC,
  keyId: APNS_KEY_ID,
  teamId: APNS_TEAM_ID,
  keyPath: APNS_KEY_PATH,
  logger: console,
});

/**
 * Send a push and log the result in the legacy `[APNs] <status> <body>`
 * format so existing log filters / dashboards keep working. Returns
 * `{status, body}` from APNs; throws if the request itself failed.
 */
async function sendPush(token, pushPayload) {
  const result = await apnsClient.sendPush(token, pushPayload);
  const tag = result.retried ? " (retried)" : "";
  console.log(`[APNs] ${result.status} ${result.body || "OK"}${tag}`);
  return result;
}

// --- Relay WebSocket ---
function connectRelay() {
  console.log(`[Relay] Connecting to ${RELAY_URL}...`);
  const ws = new WebSocket(RELAY_URL);

  let pingTimer = null;
  let pongTimer = null;

  function startHeartbeat() {
    pingTimer = setInterval(() => {
      if (ws.readyState !== WebSocket.OPEN) return;
      ws.ping();
      pongTimer = setTimeout(() => {
        console.error("[Relay] Pong timeout — connection stale, forcing reconnect");
        ws.terminate();
      }, PONG_TIMEOUT);
    }, PING_INTERVAL);
  }

  function stopHeartbeat() {
    if (pingTimer) clearInterval(pingTimer);
    if (pongTimer) clearTimeout(pongTimer);
  }

  ws.on("pong", () => {
    if (pongTimer) clearTimeout(pongTimer);
  });

  ws.on("open", () => {
    console.log("[Relay] Connected");
    const filter = {
      kinds: [24133],
      since: Math.floor(Date.now() / 1000),
    };
    const sub = JSON.stringify(["REQ", "clave-watch", filter]);
    ws.send(sub);
    console.log("[Relay] Watching kind:24133 events for all registered signer pubkeys");
    startHeartbeat();
  });

  ws.on("message", async (data) => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg[0] !== "EVENT" || msg[1] !== "clave-watch") return;
      const event = msg[2];
      if (!event || event.kind !== 24133) return;
      await dispatchCaughtEvent({
        event,
        sourceUrl: PUBLIC_PRIMARY_URL,
        classification: "PRIMARY",
      });
    } catch (e) {
      console.error("[Relay] Message handler error:", e.message);
    }
  });

  ws.on("close", () => {
    stopHeartbeat();
    console.log("[Relay] Disconnected. Reconnecting in 5s...");
    setTimeout(connectRelay, 5000);
  });

  ws.on("error", (e) => {
    console.error("[Relay] Error:", e.message);
  });
}

// --- HTTP Server for token registration ---
const server = http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/register") {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", async () => {
      try {
        const authHeader = req.headers["x-clave-auth"];
        if (!authHeader) {
          console.log(`[HTTP] /register 401: Missing X-Clave-Auth header`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing X-Clave-Auth header" }));
        }

        let authEvent;
        try {
          authEvent = parseAuthHeader(authHeader);
        } catch (e) {
          console.log(`[HTTP] /register 401: ${e.message}`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: e.message }));
        }

        const expectedUrl = `https://proxy.clave.casa/register`;
        const bodyHash = sha256Hex(Buffer.from(body));
        const result = await verifyNip98(authEvent, expectedUrl, "POST", bodyHash);
        if (!result.valid) {
          console.log(`[HTTP] /register auth failed: ${result.error}`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: result.error }));
        }

        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Invalid JSON body" }));
        }

        const { token } = parsed;
        if (!token || typeof token !== "string") {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing or invalid token" }));
        }

        storage.upsertToken({ token, pubkey: result.pubkey });
        if (relayPool) relayPool.refreshFilter();
        console.log(
          `[HTTP] Registered ${token.slice(0, 8)}... for pubkey ${result.pubkey.slice(0, 8)}...`
        );

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        console.error("[HTTP] /register error:", e.message);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Internal error" }));
      }
    });
  } else if (req.method === "POST" && req.url === "/unregister") {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", async () => {
      try {
        const authHeader = req.headers["x-clave-auth"];
        if (!authHeader) {
          console.log(`[HTTP] /unregister 401: Missing X-Clave-Auth header`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing X-Clave-Auth header" }));
        }

        let authEvent;
        try {
          authEvent = parseAuthHeader(authHeader);
        } catch (e) {
          console.log(`[HTTP] /unregister 401: ${e.message}`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: e.message }));
        }

        const expectedUrl = `https://proxy.clave.casa/unregister`;
        const bodyHash = sha256Hex(Buffer.from(body));
        const result = await verifyNip98(authEvent, expectedUrl, "POST", bodyHash);
        if (!result.valid) {
          console.log(`[HTTP] /unregister auth failed: ${result.error}`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: result.error }));
        }

        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Invalid JSON body" }));
        }

        const { token } = parsed;
        if (!token || typeof token !== "string") {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing or invalid token" }));
        }

        storage.removeToken({ token, pubkey: result.pubkey });
        if (relayPool) relayPool.refreshFilter();
        console.log(
          `[HTTP] Unregistered ${token.slice(0, 8)}... for pubkey ${result.pubkey.slice(0, 8)}...`
        );

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        console.error("[HTTP] /unregister error:", e.message);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Internal error" }));
      }
    });
  } else if (req.method === "POST" && req.url === "/pair-client") {
    let body = "";
    req.on("data", (d) => {
      body += d;
      if (body.length > MAX_BODY_SIZE) {
        req.destroy();
      }
    });
    req.on("end", async () => {
      try {
        const authHeader = req.headers["x-clave-auth"];
        if (!authHeader) {
          console.log(`[HTTP] /pair-client 401: Missing X-Clave-Auth header`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing X-Clave-Auth header" }));
        }

        let authEvent;
        try {
          authEvent = parseAuthHeader(authHeader);
        } catch (e) {
          console.log(`[HTTP] /pair-client 401: ${e.message}`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: e.message }));
        }

        const expectedUrl = `https://proxy.clave.casa/pair-client`;
        const bodyHash = sha256Hex(Buffer.from(body));
        const result = await verifyNip98(authEvent, expectedUrl, "POST", bodyHash);
        if (!result.valid) {
          console.log(`[HTTP] /pair-client auth failed: ${result.error}`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: result.error }));
        }

        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "invalid_body" }));
        }

        const { client_pubkey, relay_urls } = parsed;
        if (typeof client_pubkey !== "string" || !/^[0-9a-f]{64}$/.test(client_pubkey)) {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "invalid_client_pubkey" }));
        }
        if (!Array.isArray(relay_urls) || relay_urls.some((u) => typeof u !== "string")) {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "invalid_relay_urls" }));
        }
        if (relay_urls.length === 0) {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "no_relays" }));
        }
        if (relay_urls.length > 10) {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "relay_limit_per_pair", limit: 10, requested: relay_urls.length }));
        }
        // Validate each URL is parseable and ws/wss before passing to relayPool.addRelay —
        // the `ws` constructor throws synchronously on malformed input, which would leave
        // clients.json and the pool out of sync if we didn't pre-validate.
        for (const url of relay_urls) {
          let parsed;
          try {
            parsed = new URL(url);
          } catch {
            res.writeHead(400, { "Content-Type": "application/json" });
            return res.end(JSON.stringify({ error: "invalid_relay_url", url }));
          }
          if (parsed.protocol !== "wss:" && parsed.protocol !== "ws:") {
            res.writeHead(400, { "Content-Type": "application/json" });
            return res.end(JSON.stringify({ error: "invalid_relay_url", url }));
          }
        }

        const signerPubkey = result.pubkey;
        const existingCount = clientsStorage.countBySigner(signerPubkey);
        // Count upsert as 1 if (signer,client) already exists; else +1.
        const alreadyPaired = clientsStorage.loadAll()
          .some((p) => p.signerPubkey === signerPubkey && p.clientPubkey === client_pubkey);
        const projectedCount = alreadyPaired ? existingCount : existingCount + 1;
        if (projectedCount > 5) {
          res.writeHead(409, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "pairing_limit", limit: 5, used: existingCount }));
        }

        const novel = clientsStorage.novelRelayCount(signerPubkey, relay_urls);
        if (novel > 50) {
          res.writeHead(409, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "novel_relay_quota", limit: 50 }));
        }

        clientsStorage.addPair({ signerPubkey, clientPubkey: client_pubkey, relayUrls: relay_urls });
        for (const url of relay_urls) {
          relayPool.addRelay(url);
        }
        console.log(
          `[HTTP] Paired client ${client_pubkey.slice(0, 8)}... for signer ${signerPubkey.slice(0, 8)}... with ${relay_urls.length} relays`
        );

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        console.error("[HTTP] /pair-client error:", e.message);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Internal error" }));
      }
    });
  } else if (req.method === "POST" && req.url === "/unpair-client") {
    let body = "";
    req.on("data", (d) => {
      body += d;
      if (body.length > MAX_BODY_SIZE) {
        req.destroy();
      }
    });
    req.on("end", async () => {
      try {
        const authHeader = req.headers["x-clave-auth"];
        if (!authHeader) {
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing X-Clave-Auth header" }));
        }

        let authEvent;
        try {
          authEvent = parseAuthHeader(authHeader);
        } catch (e) {
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: e.message }));
        }

        const expectedUrl = `https://proxy.clave.casa/unpair-client`;
        const bodyHash = sha256Hex(Buffer.from(body));
        const result = await verifyNip98(authEvent, expectedUrl, "POST", bodyHash);
        if (!result.valid) {
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: result.error }));
        }

        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "invalid_body" }));
        }

        const { client_pubkey } = parsed;
        if (typeof client_pubkey !== "string" || !/^[0-9a-f]{64}$/.test(client_pubkey)) {
          res.writeHead(400, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "invalid_client_pubkey" }));
        }

        const signerPubkey = result.pubkey;
        const removed = clientsStorage.removePair({ signerPubkey, clientPubkey: client_pubkey });
        if (removed) {
          if (Array.isArray(removed.relayUrls)) {
            for (const url of removed.relayUrls) {
              relayPool.releaseRelay(url);
            }
          }
          console.log(
            `[HTTP] Unpaired client ${client_pubkey.slice(0, 8)}... for signer ${signerPubkey.slice(0, 8)}...`
          );
        } else {
          console.log(
            `[HTTP] /unpair-client: no pair found for signer ${signerPubkey.slice(0, 8)}... / client ${client_pubkey.slice(0, 8)}...`
          );
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        console.error("[HTTP] /unpair-client error:", e.message);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Internal error" }));
      }
    });
  } else if (req.method === "GET" && req.url === "/health") {
    const allTokens = storage.loadTokens();
    const pubkeys = new Set(allTokens.map((t) => t.pubkey));
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        ok: true,
        total_tokens: allTokens.length,
        unique_pubkeys: pubkeys.size,
        last_event_received_at: global.lastEventReceivedAt || null,
        uptime_seconds: Math.floor(process.uptime()),
        public_relay: process.env.PUBLIC_RELAY_URL || RELAY_URL,
        apns: apnsClient.getStats(),
      })
    );
  } else {
    res.writeHead(404);
    res.end("Not found");
  }
});

// Shared push pipeline: both the primary-sub handler (inside connectRelay)
// and the secondary-relay pool route caught kind:24133 events through this.
// sourceUrl is the relay the event was seen on, classification is PRIMARY|SECONDARY.
async function dispatchCaughtEvent({ event, sourceUrl, classification }) {
  const pTag = (event.tags || []).find((t) => t[0] === "p");
  if (!pTag || !pTag[1]) return;
  const targetPubkey = pTag[1];

  // Guard against the signer p-tagging themselves (shouldn't happen in practice)
  if (event.pubkey === targetPubkey) return;

  const matchingTokens = storage.findByPubkey(targetPubkey);
  if (matchingTokens.length === 0) {
    console.log(
      `[${classification}] Event for pubkey ${targetPubkey.slice(0, 8)}... — no registered tokens, skipping`
    );
    return;
  }

  if (alreadySeen(event.id)) return;

  console.log(
    `[Compliance] source=${sourceUrl} class=${classification} client=${event.pubkey.slice(0, 8)} signer=${targetPubkey.slice(0, 8)} event=${event.id.slice(0, 8)} ts=${new Date().toISOString()}`
  );

  global.lastEventReceivedAt = new Date().toISOString();

  const pushPayload = {
    aps: {
      "mutable-content": 1,
      "interruption-level": "passive",
      alert: { title: " ", body: " " },
    },
    relay_url: classification === "PRIMARY" ? PUBLIC_PRIMARY_URL : sourceUrl,
    event_id: event.id,
    signer_pubkey: targetPubkey,
  };

  // Embed the caught event so NSE doesn't have to race the relay's ephemeral
  // retention window. APNs alert payload cap is 4KB; 3415B leaves ~300B for
  // the aps container after signer_pubkey (~85B). Oversized events fall through
  // to NSE's existing
  // fetch-from-relay path (same broken behavior as build 21, no regression).
  const eventJSON = JSON.stringify(event);
  const eventBytes = Buffer.byteLength(eventJSON);
  if (eventBytes <= 3415) {
    pushPayload.event = event;
  } else {
    console.log(
      `[Push] Event ${event.id.slice(0, 8)} too large (${eventBytes}B), omitting embed — NSE will fall back to relay fetch`
    );
  }

  for (const entry of matchingTokens) {
    try {
      const { status, body } = await sendPush(entry.token, pushPayload);
      if (shouldPruneToken(status, body)) {
        storage.removeToken({ token: entry.token, pubkey: entry.pubkey });
        const reason = parseReason(body) || (status === 410 ? "Unregistered" : `HTTP ${status}`);
        apnsClient.noteTokenPruned(reason);
        console.log(
          `[APNs] Removed stale token: ${entry.token.slice(0, 8)}... for ${entry.pubkey.slice(0, 8)}... (${reason})`
        );
      }
    } catch (e) {
      console.error(`[APNs] Push failed for ${entry.token.slice(0, 8)}...: ${e.message}`);
    }
  }
}

function handleSecondaryEvent(relayUrl, event) {
  dispatchCaughtEvent({ event, sourceUrl: relayUrl, classification: "SECONDARY" }).catch((e) => {
    console.error(`[Secondary] dispatch error: ${e.message}`);
  });
}

// Initialize the secondary-relay pool at module scope BEFORE server.listen so
// incoming requests to /pair-client (which arrive the moment listen() returns)
// never race with pool init. The pool has no network cost until addRelay is
// called, so safe to create eagerly.
relayPool = createRelayPool({
  signerPubkeysProvider: () => [...new Set(storage.loadTokens().map((t) => t.pubkey))],
  onEvent: (relayUrl, event) => handleSecondaryEvent(relayUrl, event),
  logger: console,
});

// Boot-time restoration: open secondary subs for every paired relay URL.
// Deduplicated by relayPool's ref counting (union across pairings).
{
  const allPairs = clientsStorage.loadAll();
  const bootRelays = new Set(allPairs.flatMap((p) => p.relayUrls));
  for (const url of bootRelays) {
    if (url === PUBLIC_PRIMARY_URL) continue; // skip primary
    relayPool.addRelay(url);
  }
  if (bootRelays.size > 0) {
    console.log(`[Boot] Restored ${bootRelays.size} secondary relay subs from clients.json`);
  }
}

server.listen(HTTP_PORT, () => {
  console.log(`[HTTP] Listening on port ${HTTP_PORT}`);
  // Primary sub (ws://localhost:7778) — unchanged behavior, broad filter.
  connectRelay();
});

// Graceful shutdown — close the APNs session so Apple sees a clean
// disconnect rather than a half-open socket. Helps the next start come up
// faster and avoids a tail of stranded streams on Apple's side.
function gracefulShutdown(signal) {
  console.log(`[Shutdown] ${signal} received — closing APNs session`);
  try {
    apnsClient.close();
  } catch (e) {
    console.error(`[Shutdown] apnsClient.close threw: ${e.message}`);
  }
  // Give in-flight requests up to 2s to drain, then exit.
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT", () => gracefulShutdown("SIGINT"));
