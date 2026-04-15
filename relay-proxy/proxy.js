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

const storage = createStorage(TOKEN_FILE);
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

// --- State ---
let cachedJwt = null;
let cachedJwtTime = 0;

// --- APNs JWT (ES256) ---
function derToRaw(derSig) {
  let offset = 2;
  if (derSig[0] !== 0x30) throw new Error("Invalid DER");
  if (derSig[2] !== 0x02) throw new Error("Invalid DER");
  const rLen = derSig[3];
  const r = derSig.subarray(4, 4 + rLen);
  offset = 4 + rLen;
  if (derSig[offset] !== 0x02) throw new Error("Invalid DER");
  const sLen = derSig[offset + 1];
  const s = derSig.subarray(offset + 2, offset + 2 + sLen);
  const rPad = Buffer.alloc(32);
  r.copy(rPad, Math.max(0, 32 - r.length), Math.max(0, r.length - 32));
  const sPad = Buffer.alloc(32);
  s.copy(sPad, Math.max(0, 32 - s.length), Math.max(0, s.length - 32));
  return Buffer.concat([rPad, sPad]);
}

function makeApnsJwt() {
  // Cache JWT for 50 minutes (Apple allows up to 60)
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwtTime < 3000) return cachedJwt;

  const key = fs.readFileSync(APNS_KEY_PATH, "utf8");
  const header = Buffer.from(
    JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID })
  ).toString("base64url");
  const payload = Buffer.from(
    JSON.stringify({ iss: APNS_TEAM_ID, iat: now })
  ).toString("base64url");
  const sigInput = `${header}.${payload}`;
  const signer = crypto.createSign("SHA256");
  signer.update(sigInput);
  const sig = signer.sign(key);
  const raw = derToRaw(sig);
  const signature = raw.toString("base64url");
  cachedJwt = `${header}.${payload}.${signature}`;
  cachedJwtTime = now;
  return cachedJwt;
}

// --- APNs HTTP/2 Client ---
let apnsClient = null;

function getApnsClient() {
  if (apnsClient && !apnsClient.destroyed) return apnsClient;
  apnsClient = http2.connect(`https://${APNS_HOST}`);
  apnsClient.on("error", (err) => {
    console.error("[APNs] Connection error:", err.message);
    apnsClient = null;
  });
  apnsClient.on("close", () => {
    apnsClient = null;
  });
  return apnsClient;
}

// --- Send APNs Push ---
function sendPush(token, pushPayload) {
  const jwt = makeApnsJwt();
  const body = JSON.stringify(pushPayload);
  const client = getApnsClient();

  return new Promise((resolve, reject) => {
    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${token}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body),
    });

    let data = "";
    req.on("response", (headers) => {
      const status = headers[":status"];
      req.on("data", (d) => (data += d));
      req.on("end", () => {
        console.log(`[APNs] ${status} ${data || "OK"}`);
        resolve(status);
      });
    });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
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

      global.lastEventReceivedAt = new Date().toISOString();

      const event = msg[2];

      // Extract the signer pubkey from the p-tag on the kind:24133 event
      const pTag = (event.tags || []).find((t) => t[0] === "p");
      if (!pTag || !pTag[1]) {
        console.log(`[Relay] Event ${event.id.slice(0, 8)}... has no p-tag, skipping`);
        return;
      }
      const targetPubkey = pTag[1];

      // Skip responses from the signer themselves (pubkey === targetPubkey means the
      // signer is p-tagging themselves, which doesn't happen in practice since responses
      // are p-tagged to the client, but skip for safety)
      if (event.pubkey === targetPubkey) return;

      const matchingTokens = storage.findByPubkey(targetPubkey);
      if (matchingTokens.length === 0) {
        console.log(
          `[Relay] Event for pubkey ${targetPubkey.slice(0, 8)}... — no registered tokens, skipping`
        );
        return;
      }

      if (alreadySeen(event.id)) {
        console.log(`[Relay] Duplicate event ${event.id.slice(0, 8)}..., skipping`);
        return;
      }

      console.log(
        `[Relay] Event for pubkey ${targetPubkey.slice(0, 8)}... — pushing to ${matchingTokens.length} device(s)`
      );

      const pushPayload = {
        aps: {
          "mutable-content": 1,
          "interruption-level": "passive",
          alert: { title: " ", body: " " },
        },
        relay_url: process.env.PUBLIC_RELAY_URL || RELAY_URL,
        event_id: event.id,
      };

      for (const entry of matchingTokens) {
        try {
          const status = await sendPush(entry.token, pushPayload);
          if (status === 410) {
            storage.removeToken({ token: entry.token, pubkey: entry.pubkey });
            console.log(
              `[APNs] Removed stale token: ${entry.token.slice(0, 8)}... for ${entry.pubkey.slice(0, 8)}...`
            );
          }
        } catch (e) {
          console.error(
            `[APNs] Push failed for ${entry.token.slice(0, 8)}...: ${e.message}`
          );
        }
      }
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
        const authHeader = req.headers.authorization;
        if (!authHeader) {
          console.log(`[HTTP] /register 401: Missing Authorization header`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing Authorization header" }));
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
        const authHeader = req.headers.authorization;
        if (!authHeader) {
          console.log(`[HTTP] /unregister 401: Missing Authorization header`);
          res.writeHead(401, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ error: "Missing Authorization header" }));
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
      })
    );
  } else {
    res.writeHead(404);
    res.end("Not found");
  }
});

server.listen(HTTP_PORT, () => {
  console.log(`[HTTP] Listening on port ${HTTP_PORT}`);
  connectRelay();
});
