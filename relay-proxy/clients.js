const fs = require("node:fs");

function createClientsStorage(filePath) {
  function isValidPair(p) {
    return p && typeof p === "object"
      && typeof p.signerPubkey === "string"
      && typeof p.clientPubkey === "string"
      && Array.isArray(p.relayUrls)
      && typeof p.createdAt === "number"
      && typeof p.lastSeenAt === "number";
  }

  function loadAll() {
    if (!fs.existsSync(filePath)) return [];
    try {
      const raw = fs.readFileSync(filePath, "utf8");
      if (!raw.trim()) return [];
      const data = JSON.parse(raw);
      return Array.isArray(data) ? data.filter(isValidPair) : [];
    } catch {
      return [];
    }
  }

  function saveAll(pairs) {
    const tmp = filePath + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(pairs, null, 2), { mode: 0o644 });
    fs.renameSync(tmp, filePath);
  }

  function addPair({ signerPubkey, clientPubkey, relayUrls }) {
    const all = loadAll();
    const now = Math.floor(Date.now() / 1000);
    const idx = all.findIndex((p) => p.signerPubkey === signerPubkey && p.clientPubkey === clientPubkey);
    if (idx >= 0) {
      all[idx].relayUrls = relayUrls;
      all[idx].lastSeenAt = now;
    } else {
      all.push({ signerPubkey, clientPubkey, relayUrls, createdAt: now, lastSeenAt: now });
    }
    saveAll(all);
  }

  function removePair({ signerPubkey, clientPubkey }) {
    const all = loadAll();
    const idx = all.findIndex((p) => p.signerPubkey === signerPubkey && p.clientPubkey === clientPubkey);
    if (idx < 0) return null;
    const [removed] = all.splice(idx, 1);
    saveAll(all);
    return removed;
  }

  function removeBySigner(signerPubkey) {
    const all = loadAll();
    const removed = all.filter((p) => p.signerPubkey === signerPubkey);
    if (removed.length === 0) return [];
    const remaining = all.filter((p) => p.signerPubkey !== signerPubkey);
    saveAll(remaining);
    return removed;
  }

  function countBySigner(signerPubkey) {
    return loadAll().filter((p) => p.signerPubkey === signerPubkey).length;
  }

  return { loadAll, addPair, removePair, removeBySigner, countBySigner };
}

module.exports = { createClientsStorage };
