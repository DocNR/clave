const WebSocket = require("ws");

const SUB_ID = "clave-watch";
const PRIMARY_RELAY_URL = "wss://relay.powr.build";

function createRelayPool({
  createSocket = (url) => new WebSocket(url),
  signerPubkeysProvider = () => [],
  onEvent = () => {},
  logger = console,
} = {}) {
  // URL → { ws, refCount, state, url }
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
    } catch (e) {
      // best-effort
    }
  }

  function attachHandlers(entry) {
    entry.ws.on("open", () => {
      entry.state = "ready";
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
    });

    entry.ws.on("error", (err) => {
      logger.error(`[RelayPool] ${entry.url} error: ${err.message}`);
    });
  }

  function addRelay(url) {
    if (url === PRIMARY_RELAY_URL) return; // covered by top-level primary sub in proxy.js
    const existing = pool.get(url);
    if (existing) {
      existing.refCount++;
      return;
    }
    const entry = {
      url,
      ws: createSocket(url),
      refCount: 1,
      state: "connecting",
    };
    pool.set(url, entry);
    attachHandlers(entry);
  }

  function releaseRelay(url) {
    const entry = pool.get(url);
    if (!entry) return;
    entry.refCount--;
    if (entry.refCount <= 0) {
      sendClose(entry);
      try {
        entry.ws.close();
      } catch {}
      pool.delete(url);
    }
  }

  function getState(url) {
    const entry = pool.get(url);
    if (!entry) return null;
    return { url: entry.url, refCount: entry.refCount, state: entry.state };
  }

  function listUrls() {
    return Array.from(pool.keys());
  }

  function refreshFilter() {
    for (const entry of pool.values()) {
      if (!entry.ws || entry.ws.readyState !== WebSocket.OPEN) continue;
      sendClose(entry);
      sendReq(entry);
    }
  }

  return { addRelay, releaseRelay, refreshFilter, getState, listUrls };
}

module.exports = { createRelayPool };
