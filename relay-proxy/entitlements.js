const fs = require("node:fs");

const FREE_TIER_CAPS = Object.freeze({
  maxAccounts: 4,
  maxClients: 5,
});

const PREMIUM_TIER_CAPS = Object.freeze({
  maxAccounts: 10,
  maxClients: 30,
});

const VALID_TIERS = new Set(["free", "premium"]);
const HEX_PUBKEY_RE = /^[0-9a-f]{64}$/;

// Compute effective tier from a stored entry, treating expired premium as free.
// expires_at: null → no expiry. expires_at: number → unix seconds; tier downgrades
// to "free" once now >= expires_at. Phase 1 only writes null; Phase 2 (Lightning
// time-bounded grants, if introduced) writes timestamps.
function effectiveTier(entry) {
  if (!entry) return "free";
  if (entry.expires_at !== null && typeof entry.expires_at === "number") {
    const now = Math.floor(Date.now() / 1000);
    if (entry.expires_at <= now) return "free";
  }
  return entry.tier;
}

function createEntitlementsStorage(filePath) {
  function isValidEntry(e) {
    return e && typeof e === "object"
      && typeof e.tier === "string"
      && VALID_TIERS.has(e.tier)
      && typeof e.granted_at === "number"
      && (e.granted_by === undefined || typeof e.granted_by === "string")
      && (e.expires_at === null || typeof e.expires_at === "number")
      && (e.note === undefined || typeof e.note === "string")
      && (e.devices_seen === undefined || Array.isArray(e.devices_seen));
  }

  function loadAll() {
    if (!fs.existsSync(filePath)) return {};
    try {
      const raw = fs.readFileSync(filePath, "utf8");
      if (!raw.trim()) return {};
      const data = JSON.parse(raw);
      if (!data || typeof data !== "object" || Array.isArray(data)) return {};
      const filtered = {};
      for (const [pubkey, entry] of Object.entries(data)) {
        if (HEX_PUBKEY_RE.test(pubkey) && isValidEntry(entry)) {
          filtered[pubkey] = entry;
        }
      }
      return filtered;
    } catch {
      return {};
    }
  }

  function saveAll(entries) {
    const tmp = filePath + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(entries, null, 2), { mode: 0o644 });
    fs.renameSync(tmp, filePath);
  }

  function getByPubkey(pubkeyHex) {
    return loadAll()[pubkeyHex] || null;
  }

  // Upserts entitlement at pubkeyHex. Preserves granted_at and devices_seen
  // across updates; granted_by/note are overwritten when supplied (use undefined
  // to keep existing). Set expires_at: null for no-expiry; pass a number to
  // override. Throws on invalid pubkey hex or tier.
  function setEntitlement(pubkeyHex, fields) {
    if (!HEX_PUBKEY_RE.test(pubkeyHex)) throw new Error("invalid_pubkey_hex");
    if (!fields || typeof fields !== "object") throw new Error("invalid_fields");
    const { tier, granted_by, note } = fields;
    const expires_at = fields.expires_at !== undefined ? fields.expires_at : null;
    if (!VALID_TIERS.has(tier)) throw new Error("invalid_tier");
    if (expires_at !== null && typeof expires_at !== "number") throw new Error("invalid_expires_at");

    const all = loadAll();
    const existing = all[pubkeyHex];
    const now = Math.floor(Date.now() / 1000);
    const next = {
      tier,
      granted_at: existing ? existing.granted_at : now,
      expires_at,
      devices_seen: existing && Array.isArray(existing.devices_seen) ? existing.devices_seen : [],
    };
    const resolvedGrantedBy = granted_by !== undefined ? granted_by : existing && existing.granted_by;
    const resolvedNote = note !== undefined ? note : existing && existing.note;
    if (resolvedGrantedBy !== undefined) next.granted_by = resolvedGrantedBy;
    if (resolvedNote !== undefined) next.note = resolvedNote;
    all[pubkeyHex] = next;
    saveAll(all);
    return next;
  }

  function revoke(pubkeyHex) {
    const all = loadAll();
    if (!all[pubkeyHex]) return null;
    const removed = all[pubkeyHex];
    delete all[pubkeyHex];
    saveAll(all);
    return removed;
  }

  function tierForPubkey(pubkeyHex) {
    return effectiveTier(getByPubkey(pubkeyHex));
  }

  // Records a device's APNs token prefix seen for this pubkey. Returns true if
  // recorded, false if pubkey has no entitlement (we don't auto-create) or
  // tokenPrefix is empty. Dedupes by token_prefix and updates last_seen_at on
  // existing entries.
  function recordDevice(pubkeyHex, tokenPrefix) {
    if (typeof tokenPrefix !== "string" || tokenPrefix.length === 0) return false;
    const all = loadAll();
    if (!all[pubkeyHex]) return false;
    const entry = all[pubkeyHex];
    if (!Array.isArray(entry.devices_seen)) entry.devices_seen = [];
    const now = Math.floor(Date.now() / 1000);
    const idx = entry.devices_seen.findIndex((d) => d && d.token_prefix === tokenPrefix);
    if (idx >= 0) {
      entry.devices_seen[idx].last_seen_at = now;
    } else {
      entry.devices_seen.push({ token_prefix: tokenPrefix, first_seen_at: now, last_seen_at: now });
    }
    saveAll(all);
    return true;
  }

  // Returns pubkeys whose distinct device count within the past `withinDays`
  // exceeds `thresholdDevices`. Used by the abuse-tripwire audit CLI.
  function auditMultiDevice(thresholdDevices, withinDays) {
    const cutoff = Math.floor(Date.now() / 1000) - withinDays * 86400;
    const all = loadAll();
    const flagged = [];
    for (const [pubkey, entry] of Object.entries(all)) {
      if (!Array.isArray(entry.devices_seen)) continue;
      const recent = entry.devices_seen.filter(
        (d) => d && typeof d.last_seen_at === "number" && d.last_seen_at >= cutoff
      );
      if (recent.length > thresholdDevices) {
        flagged.push({ pubkey, deviceCount: recent.length, tier: effectiveTier(entry) });
      }
    }
    return flagged;
  }

  function listByTier(tier) {
    if (!VALID_TIERS.has(tier)) return [];
    const all = loadAll();
    const out = [];
    for (const [pubkey, entry] of Object.entries(all)) {
      if (effectiveTier(entry) === tier) out.push({ pubkey, ...entry });
    }
    return out;
  }

  function maxAccountsForTier(tier) {
    return tier === "premium" ? PREMIUM_TIER_CAPS.maxAccounts : FREE_TIER_CAPS.maxAccounts;
  }

  function maxClientsForTier(tier) {
    return tier === "premium" ? PREMIUM_TIER_CAPS.maxClients : FREE_TIER_CAPS.maxClients;
  }

  return {
    loadAll,
    getByPubkey,
    setEntitlement,
    revoke,
    tierForPubkey,
    recordDevice,
    auditMultiDevice,
    listByTier,
    maxAccountsForTier,
    maxClientsForTier,
  };
}

module.exports = {
  createEntitlementsStorage,
  FREE_TIER_CAPS,
  PREMIUM_TIER_CAPS,
};
