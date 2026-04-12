const WebSocket = require("ws");
const http = require("http");
const http2 = require("http2");
const crypto = require("crypto");
const fs = require("fs");

// --- Configuration (set via env vars) ---
const RELAY_URL = process.env.RELAY_URL || "wss://relay.powr.build";
const SIGNER_PUBKEY = process.env.SIGNER_PUBKEY;
const APNS_KEY_PATH = process.env.APNS_KEY_PATH || "./AuthKey.p8";
const APNS_KEY_ID = process.env.APNS_KEY_ID;
const APNS_TEAM_ID = process.env.APNS_TEAM_ID;
const APNS_TOPIC = "dev.nostr.clave";
const APNS_HOST = "api.sandbox.push.apple.com";
const TOKEN_FILE = "./tokens.json";
const HTTP_PORT = process.env.PORT || 3000;

if (!SIGNER_PUBKEY) {
  console.error("SIGNER_PUBKEY env var required");
  process.exit(1);
}
if (!APNS_KEY_ID || !APNS_TEAM_ID) {
  console.error("APNS_KEY_ID and APNS_TEAM_ID env vars required");
  process.exit(1);
}

// --- State ---
let deviceTokens = [];
try {
  deviceTokens = JSON.parse(fs.readFileSync(TOKEN_FILE, "utf8"));
} catch {}
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

  ws.on("open", () => {
    console.log("[Relay] Connected");
    const sub = JSON.stringify([
      "REQ",
      "clave-watch",
      {
        kinds: [24133],
        since: Math.floor(Date.now() / 1000),
      },
    ]);
    ws.send(sub);
    console.log(
      `[Relay] Watching kind:24133 for ${SIGNER_PUBKEY.slice(0, 8)}...`
    );
  });

  ws.on("message", async (data) => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg[0] === "EVENT" && msg[1] === "clave-watch") {
        const event = msg[2];
        // Skip our own responses (from the signer)
        if (event.pubkey === SIGNER_PUBKEY) return;
        console.log(
          `[Relay] Signing request from ${event.pubkey.slice(0, 8)}...`
        );

        if (deviceTokens.length === 0) {
          console.log("[Relay] No device tokens registered — skipping push");
          return;
        }

        const pushPayload = {
          aps: {
            "mutable-content": 1,
            alert: { title: "Clave", body: "Signing request" },
          },
          relay_url: RELAY_URL,
          event_id: event.id,
        };

        // Debounce: skip push if we sent one within the last 3 seconds
        const now = Date.now();
        if (global.lastPushTime && now - global.lastPushTime < 3000) {
          console.log("[Relay] Debounced — push sent recently");
          return;
        }
        global.lastPushTime = now;

        for (let i = deviceTokens.length - 1; i >= 0; i--) {
          const token = deviceTokens[i];
          try {
            const status = await sendPush(token, pushPayload);
            if (status === 410) {
              deviceTokens.splice(i, 1);
              fs.writeFileSync(TOKEN_FILE, JSON.stringify(deviceTokens, null, 2));
              console.log(`[APNs] Removed stale token: ${token.slice(0, 8)}...`);
            }
          } catch (e) {
            console.error(
              `[APNs] Failed for ${token.slice(0, 8)}...: ${e.message}`
            );
          }
        }
      }
    } catch {}
  });

  ws.on("close", () => {
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
    req.on("end", () => {
      try {
        const { token } = JSON.parse(body);
        if (token && !deviceTokens.includes(token)) {
          deviceTokens.push(token);
          fs.writeFileSync(TOKEN_FILE, JSON.stringify(deviceTokens, null, 2));
          console.log(`[HTTP] Registered token: ${token.slice(0, 8)}...`);
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch {
        res.writeHead(400);
        res.end("Bad request");
      }
    });
  } else if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        tokens: deviceTokens.length,
        relay: RELAY_URL,
        signer: SIGNER_PUBKEY.slice(0, 8) + "...",
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
