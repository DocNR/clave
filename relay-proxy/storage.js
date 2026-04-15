const fs = require("node:fs");

function createStorage(filePath) {
  function readFileOrEmpty() {
    if (!fs.existsSync(filePath)) return [];
    try {
      const raw = fs.readFileSync(filePath, "utf8");
      if (!raw.trim()) return [];
      return JSON.parse(raw);
    } catch {
      return [];
    }
  }

  function writeFile(data) {
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
  }

  function loadTokens() {
    const data = readFileOrEmpty();
    // Only return entries that match the new schema
    return Array.isArray(data) && data.every((d) => typeof d === "object" && d.token && d.pubkey)
      ? data
      : [];
  }

  function upsertToken({ token, pubkey }) {
    const tokens = loadTokens();
    const now = Math.floor(Date.now() / 1000);
    const idx = tokens.findIndex((t) => t.token === token && t.pubkey === pubkey);
    if (idx >= 0) {
      tokens[idx].last_seen = now;
    } else {
      tokens.push({ token, pubkey, last_seen: now });
    }
    writeFile(tokens);
  }

  function removeToken({ token, pubkey }) {
    const tokens = loadTokens();
    const filtered = tokens.filter((t) => !(t.token === token && t.pubkey === pubkey));
    writeFile(filtered);
  }

  function findByPubkey(pubkey) {
    return loadTokens().filter((t) => t.pubkey === pubkey);
  }

  function migrateIfLegacy() {
    if (!fs.existsSync(filePath)) {
      return { migrated: false };
    }
    let raw;
    try {
      raw = JSON.parse(fs.readFileSync(filePath, "utf8"));
    } catch {
      return { migrated: false };
    }
    // Legacy format: non-empty flat array of hex strings. Empty arrays are
    // the normal clean state after tokens get unregistered — do NOT treat
    // them as legacy (would false-positive the migration and clobber the
    // real legacy-backup file on every restart).
    if (Array.isArray(raw) && raw.length > 0 && raw.every((e) => typeof e === "string")) {
      // Don't overwrite an existing backup — the first migration is the real one.
      if (!fs.existsSync(filePath + ".legacy-backup")) {
        fs.copyFileSync(filePath, filePath + ".legacy-backup");
      }
      writeFile([]);
      return { migrated: true, legacyCount: raw.length };
    }
    return { migrated: false };
  }

  return {
    loadTokens,
    upsertToken,
    removeToken,
    findByPubkey,
    migrateIfLegacy,
  };
}

module.exports = { createStorage };
