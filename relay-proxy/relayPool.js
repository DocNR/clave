const WebSocket = require("ws");

const SUB_ID = "clave-watch";
const PRIMARY_RELAY_URL = "wss://relay.powr.build";

function createRelayPool({
  createSocket = (url) => new WebSocket(url),
  signerPubkeysProvider = () => [],
  onEvent = () => {},
  logger = console,
  reconnectInitialMs = 1000,
  reconnectMaxMs = 600_000, // 10 min
} = {}) {
  const pool = new Map();

  function narrowFilter() {
    return {
      kinds: [24133],
      "#p": signerPubkeysProvider(),
      since: Math.floor(Date.now() / 1000),
    };
  }

  function sendReq(entry) {
    if (!entry.ws || entry.ws.readyState !== WebSocket.OPEN) return;
    entry.ws.send(JSON.stringify(["REQ", SUB_ID, narrowFilter()]));
  }

  function sendClose(entry) {
    if (!entry.ws || entry.ws.readyState !== WebSocket.OPEN) return;
    try {
      entry.ws.send(JSON.stringify(["CLOSE", SUB_ID]));
    } catch {}
  }

  function scheduleReconnect(entry) {
    if (entry.refCount <= 0) return; // released; don't reconnect
    if (entry.reconnectTimer) return; // already scheduled
    const delay = Math.min(entry.backoffMs, reconnectMaxMs);
    logger.log(`[RelayPool] ${entry.url} reconnecting in ${delay}ms (failures=${entry.failures})`);
    entry.reconnectTimer = setTimeout(() => {
      entry.reconnectTimer = null;
      if (entry.refCount <= 0) return;
      entry.backoffMs = Math.min(entry.backoffMs * 2, reconnectMaxMs);
      openSocket(entry);
    }, delay);
  }

  function attachHandlers(entry) {
    entry.ws.on("open", () => {
      entry.state = "ready";
      entry.backoffMs = reconnectInitialMs; // reset backoff on success
      logger.log(`[RelayPool] ${entry.url} connected`);
      sendReq(entry);
    });

    entry.ws.on("message", (data) => {
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (!Array.isArray(msg) || msg[0] !== "EVENT" || msg[1] !== SUB_ID) return;
      const event = msg[2];
      if (!event || event.kind !== 24133) return;
      try {
        onEvent(entry.url, event);
      } catch (e) {
        logger.error(`[RelayPool] onEvent threw for ${entry.url}: ${e.message}`);
      }
    });

    entry.ws.on("close", () => {
      entry.state = "closed";
      entry.failures++;
      scheduleReconnect(entry);
    });

    entry.ws.on("error", (err) => {
      logger.error(`[RelayPool] ${entry.url} error: ${err.message}`);
    });
  }

  function openSocket(entry) {
    entry.ws = createSocket(entry.url);
    entry.state = "connecting";
    attachHandlers(entry);
  }

  function addRelay(url) {
    if (url === PRIMARY_RELAY_URL) return;
    const existing = pool.get(url);
    if (existing) {
      existing.refCount++;
      return;
    }
    const entry = {
      url,
      ws: null,
      refCount: 1,
      state: "connecting",
      backoffMs: reconnectInitialMs,
      failures: 0,
      reconnectTimer: null,
    };
    pool.set(url, entry);
    openSocket(entry);
  }

  function releaseRelay(url) {
    const entry = pool.get(url);
    if (!entry) return;
    entry.refCount--;
    if (entry.refCount <= 0) {
      if (entry.reconnectTimer) clearTimeout(entry.reconnectTimer);
      sendClose(entry);
      try {
        entry.ws && entry.ws.close();
      } catch {}
      pool.delete(url);
    }
  }

  function refreshFilter() {
    for (const entry of pool.values()) {
      if (!entry.ws || entry.ws.readyState !== WebSocket.OPEN) continue;
      sendClose(entry);
      sendReq(entry);
    }
  }

  function getState(url) {
    const entry = pool.get(url);
    if (!entry) return null;
    return {
      url: entry.url,
      refCount: entry.refCount,
      state: entry.state,
      failures: entry.failures,
    };
  }

  function listUrls() {
    return Array.from(pool.keys());
  }

  function shutdown() {
    for (const entry of pool.values()) {
      if (entry.reconnectTimer) clearTimeout(entry.reconnectTimer);
      try { entry.ws && entry.ws.close(); } catch {}
    }
    pool.clear();
  }

  return { addRelay, releaseRelay, refreshFilter, getState, listUrls, shutdown };
}

module.exports = { createRelayPool };
