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

  const PRIMARY_RELAY_URL = "wss://relay.powr.build";

  function novelRelayCount(signerPubkey, proposedUrls) {
    const all = loadAll();
    const myCurrentRelays = new Set(
      all.filter((p) => p.signerPubkey === signerPubkey).flatMap((p) => p.relayUrls)
    );
    const othersRelays = new Set(
      all.filter((p) => p.signerPubkey !== signerPubkey).flatMap((p) => p.relayUrls)
    );
    const deduped = new Set(proposedUrls);
    let novel = 0;
    for (const url of deduped) {
      if (url === PRIMARY_RELAY_URL) continue;
      if (myCurrentRelays.has(url)) continue;
      if (othersRelays.has(url)) continue;
      novel++;
    }
    return novel;
  }

  function gcStale(maxAgeDays) {
    const cutoff = Math.floor(Date.now() / 1000) - maxAgeDays * 86400;
    const all = loadAll();
    const kept = all.filter((p) => p.createdAt >= cutoff);
    const removed = all.length - kept.length;
    if (removed > 0) saveAll(kept);
    return removed;
  }

  return { loadAll, addPair, removePair, removeBySigner, countBySigner, novelRelayCount, gcStale };
}

module.exports = { createClientsStorage };
