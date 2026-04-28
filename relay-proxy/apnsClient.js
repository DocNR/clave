"use strict";

/**
 * APNs HTTP/2 client wrapper with GOAWAY-aware reconnection, single-retry
 * on transient session errors, periodic health ping, and operational
 * counters. Replaces the inline implementation that previously lived in
 * proxy.js and silently went dead after Apple's GOAWAY frames.
 *
 * The previous implementation only nulled the cached session on its
 * `error` and `close` events. Apple sends a GOAWAY frame to signal
 * graceful close — after GOAWAY the session is NOT `destroyed`, just
 * unable to create new streams. The check `if (apnsClient && !apnsClient.destroyed)`
 * happily returned the dead session for every subsequent send. Result:
 * ~6 hours of zero APNs delivery on 2026-04-27 evening.
 *
 * This module:
 *  - Listens for the `goaway` event explicitly and discards the session.
 *  - Detects per-request errors that imply the session is dead
 *    (NGHTTP2_REFUSED_STREAM, ERR_HTTP2_GOAWAY_SESSION, ECONNRESET) and
 *    automatically retries once on a fresh session.
 *  - Sends an HTTP/2 PING every 5 minutes so the kernel + Apple both keep
 *    the socket warm; if the ping fails the session is replaced before the
 *    next real push.
 *  - Exposes counters for `/health` so we can detect the "stuck dead"
 *    state from outside the process next time.
 */

const http2 = require("http2");
const crypto = require("crypto");
const fs = require("fs");

// ---------------------------------------------------------------------------
// Pure helpers (exported for unit tests)
// ---------------------------------------------------------------------------

/**
 * Errors that mean "this session is dead — replace it before the next send".
 * Anything not in this set is treated as a transient per-request failure
 * (timeout, malformed body, etc.) and does NOT invalidate the session.
 */
const FATAL_SESSION_CODES = new Set([
  "ERR_HTTP2_GOAWAY_SESSION",
  "ERR_HTTP2_INVALID_SESSION",
  "ERR_HTTP2_STREAM_CANCEL",
  "ECONNRESET",
  "ECONNREFUSED",
  "EPIPE",
  "ETIMEDOUT",
]);

const FATAL_NGHTTP2_CODES = new Set([
  "NGHTTP2_REFUSED_STREAM",
  "NGHTTP2_ENHANCE_YOUR_CALM",
  "NGHTTP2_INTERNAL_ERROR",
]);

function isSessionFatalError(err) {
  if (!err) return false;
  if (err.code && FATAL_SESSION_CODES.has(err.code)) return true;
  // node http2 surfaces nghttp2 codes in the message string for some errors.
  const msg = String(err.message || "");
  for (const code of FATAL_NGHTTP2_CODES) {
    if (msg.includes(code)) return true;
  }
  if (msg.includes("GOAWAY")) return true;
  return false;
}

/**
 * Both 410 Unregistered and 400 BadDeviceToken mean "stop sending to this
 * token". Apple's docs lump them together as terminal token states. The
 * previous code only pruned on 410, leaving stale-from-reinstall tokens
 * stuck forever (one user accumulated 199 BadDeviceToken responses in 24h
 * before we noticed).
 */
function shouldPruneToken(status, body) {
  if (status === 410) return true;
  if (status === 400) {
    const reason = parseReason(body);
    if (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
      return true;
    }
  }
  return false;
}

function parseReason(body) {
  if (!body) return null;
  if (typeof body === "object") return body.reason || null;
  try {
    const parsed = JSON.parse(body);
    return parsed.reason || null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// JWT (ES256, cached for 50 min — Apple allows up to 60)
// ---------------------------------------------------------------------------

function derToRaw(derSig) {
  if (derSig[0] !== 0x30) throw new Error("Invalid DER");
  if (derSig[2] !== 0x02) throw new Error("Invalid DER");
  const rLen = derSig[3];
  const r = derSig.subarray(4, 4 + rLen);
  let offset = 4 + rLen;
  if (derSig[offset] !== 0x02) throw new Error("Invalid DER");
  const sLen = derSig[offset + 1];
  const s = derSig.subarray(offset + 2, offset + 2 + sLen);
  const rPad = Buffer.alloc(32);
  r.copy(rPad, Math.max(0, 32 - r.length), Math.max(0, r.length - 32));
  const sPad = Buffer.alloc(32);
  s.copy(sPad, Math.max(0, 32 - s.length), Math.max(0, s.length - 32));
  return Buffer.concat([rPad, sPad]);
}

// ---------------------------------------------------------------------------
// Client factory
// ---------------------------------------------------------------------------

/**
 * Create an APNs client.
 *
 * @param {object} opts
 * @param {string} opts.host           - APNs host (e.g. "api.push.apple.com").
 * @param {string} opts.topic          - APNs topic (bundle id).
 * @param {string} opts.keyId          - APNs key id (header `kid`).
 * @param {string} opts.teamId         - APNs team id (JWT `iss`).
 * @param {string} opts.keyPath        - Path to .p8 file.
 * @param {object} [opts.logger=console]
 * @param {number} [opts.pingIntervalMs=300000] - 5 min default.
 *                                                Set to 0 to disable.
 */
function createApnsClient(opts) {
  const {
    host,
    topic,
    keyId,
    teamId,
    keyPath,
    logger = console,
    pingIntervalMs = 300_000,
  } = opts;

  if (!host || !topic || !keyId || !teamId || !keyPath) {
    throw new Error("createApnsClient: missing required options");
  }

  let session = null;
  let sessionConnectedAt = 0;
  let pingTimer = null;

  let cachedJwt = null;
  let cachedJwtTime = 0;

  // Operational counters surfaced via /health.
  const stats = {
    sessionConnects: 0,
    sessionInvalidations: 0,
    sendOk: 0,
    sendFail: 0,
    sendRetried: 0,
    pruneOnBadDeviceToken: 0,
    pruneOnUnregistered: 0,
    lastSendAt: null,
    lastFailureAt: null,
    lastFailureReason: null,
  };

  function makeJwt() {
    const now = Math.floor(Date.now() / 1000);
    if (cachedJwt && now - cachedJwtTime < 3000) return cachedJwt;
    const key = fs.readFileSync(keyPath, "utf8");
    const header = Buffer.from(
      JSON.stringify({ alg: "ES256", kid: keyId })
    ).toString("base64url");
    const payload = Buffer.from(
      JSON.stringify({ iss: teamId, iat: now })
    ).toString("base64url");
    const sigInput = `${header}.${payload}`;
    const signer = crypto.createSign("SHA256");
    signer.update(sigInput);
    const sig = signer.sign(key);
    const raw = derToRaw(sig);
    cachedJwt = `${header}.${payload}.${raw.toString("base64url")}`;
    cachedJwtTime = now;
    return cachedJwt;
  }

  function clearPingTimer() {
    if (pingTimer) {
      clearInterval(pingTimer);
      pingTimer = null;
    }
  }

  function invalidateSession(reason) {
    if (!session) return;
    stats.sessionInvalidations += 1;
    logger.warn(`[APNs] Invalidating session (${reason})`);
    clearPingTimer();
    try {
      session.close();
    } catch {
      // best-effort; session may already be gone
    }
    session = null;
    sessionConnectedAt = 0;
  }

  function startPingTimer() {
    if (pingIntervalMs <= 0) return;
    clearPingTimer();
    pingTimer = setInterval(() => {
      if (!session || session.destroyed || session.closed) {
        clearPingTimer();
        return;
      }
      try {
        session.ping((err) => {
          if (err) {
            logger.warn(`[APNs] Ping failed: ${err.message}`);
            invalidateSession("ping-failed");
          }
        });
      } catch (err) {
        logger.warn(`[APNs] Ping threw: ${err.message}`);
        invalidateSession("ping-threw");
      }
    }, pingIntervalMs);
    // Don't keep the event loop alive just for this timer.
    if (typeof pingTimer.unref === "function") pingTimer.unref();
  }

  function getSession() {
    if (session && !session.destroyed && !session.closed) return session;
    session = http2.connect(`https://${host}`);
    sessionConnectedAt = Date.now();
    stats.sessionConnects += 1;

    session.on("error", (err) => {
      logger.error(`[APNs] Session error: ${err.message}`);
      invalidateSession("error-event");
    });
    session.on("close", () => {
      // close fires on both graceful and forced; null out so the next
      // request creates a new session.
      session = null;
      sessionConnectedAt = 0;
      clearPingTimer();
    });
    // GOAWAY: Apple is asking us to stop using this session for new
    // streams. The session itself stays alive briefly for in-flight
    // streams, but we must not start any new ones. Discard immediately
    // so the very next sendPush opens a fresh session.
    session.on("goaway", (errorCode, lastStreamID) => {
      logger.warn(
        `[APNs] GOAWAY received (errorCode=${errorCode}, lastStreamID=${lastStreamID})`
      );
      invalidateSession("goaway");
    });
    session.on("frameError", (type, code, id) => {
      logger.warn(
        `[APNs] frameError (type=${type}, code=${code}, streamId=${id})`
      );
      invalidateSession("frameError");
    });

    startPingTimer();
    return session;
  }

  function sendOnce(client, token, jwt, body) {
    return new Promise((resolve, reject) => {
      let req;
      try {
        req = client.request({
          ":method": "POST",
          ":path": `/3/device/${token}`,
          authorization: `bearer ${jwt}`,
          "apns-topic": topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
        });
      } catch (err) {
        // Synchronous throws (e.g. session destroyed mid-call) need to be
        // caught — otherwise they bubble up as uncaught and crash the
        // dispatcher loop.
        return reject(err);
      }

      let data = "";
      req.on("response", (headers) => {
        const status = headers[":status"];
        req.on("data", (d) => (data += d));
        req.on("end", () => {
          resolve({ status, body: data });
        });
      });
      req.on("error", reject);
      try {
        req.write(body);
        req.end();
      } catch (err) {
        reject(err);
      }
    });
  }

  /**
   * Send a single push. Auto-retries once on session-fatal errors with a
   * fresh session.
   *
   * @returns {Promise<{status:number, body:string, retried:boolean}>}
   */
  async function sendPush(token, payload) {
    const jwt = makeJwt();
    const body = JSON.stringify(payload);

    let attempt = 0;
    let lastError = null;
    while (attempt < 2) {
      const client = getSession();
      try {
        const result = await sendOnce(client, token, jwt, body);
        stats.sendOk += 1;
        stats.lastSendAt = new Date().toISOString();
        return { ...result, retried: attempt > 0 };
      } catch (err) {
        lastError = err;
        if (isSessionFatalError(err) && attempt === 0) {
          logger.warn(
            `[APNs] Session-fatal error on attempt 1 (${err.message}) — retrying on fresh session`
          );
          stats.sendRetried += 1;
          invalidateSession("send-fatal");
          attempt += 1;
          continue;
        }
        stats.sendFail += 1;
        stats.lastFailureAt = new Date().toISOString();
        stats.lastFailureReason = err.message;
        throw err;
      }
    }
    // Unreachable but keeps tooling honest.
    throw lastError || new Error("APNs send failed");
  }

  function getStats() {
    return {
      ...stats,
      sessionAlive: !!(session && !session.destroyed && !session.closed),
      sessionAgeSeconds: sessionConnectedAt
        ? Math.floor((Date.now() - sessionConnectedAt) / 1000)
        : 0,
    };
  }

  function close() {
    clearPingTimer();
    if (session && !session.destroyed) {
      try {
        session.close();
      } catch {
        // best-effort
      }
    }
    session = null;
  }

  /**
   * Record a token-pruning event for the stats counter. Called by the
   * caller (proxy.js) after it deletes a stale token from storage.
   */
  function noteTokenPruned(reason) {
    if (reason === "BadDeviceToken") stats.pruneOnBadDeviceToken += 1;
    else if (reason === "Unregistered") stats.pruneOnUnregistered += 1;
  }

  return {
    sendPush,
    getStats,
    close,
    noteTokenPruned,
    // exposed for tests + emergency manual reset
    _invalidateSession: invalidateSession,
  };
}

module.exports = {
  createApnsClient,
  isSessionFatalError,
  shouldPruneToken,
  parseReason,
  // exported only for tests
  FATAL_SESSION_CODES,
  FATAL_NGHTTP2_CODES,
};
