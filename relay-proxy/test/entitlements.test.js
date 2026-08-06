const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

function tmpFile() {
  return path.join(os.tmpdir(), `clave-entitlements-test-${Date.now()}-${Math.random()}.json`);
}

const PUB_A = "a".repeat(64);
const PUB_B = "b".repeat(64);
const PUB_C = "c".repeat(64);
const ADMIN_NPUB_HEX = "1".repeat(64);

// ---------- loadAll ----------

test("loadAll returns empty object when file doesn't exist", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.deepEqual(storage.loadAll(), {});
});

test("loadAll ignores malformed JSON", () => {
  const file = tmpFile();
  fs.writeFileSync(file, "not json {{{");
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.deepEqual(storage.loadAll(), {});
});

test("loadAll returns {} when top-level value is an array (schema drift)", () => {
  const file = tmpFile();
  fs.writeFileSync(file, JSON.stringify([{ tier: "premium", granted_at: 1 }]));
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.deepEqual(storage.loadAll(), {});
});

test("loadAll filters out non-hex pubkey keys", () => {
  const file = tmpFile();
  fs.writeFileSync(file, JSON.stringify({
    [PUB_A]: { tier: "premium", granted_at: 1, expires_at: null },
    "not-a-pubkey": { tier: "premium", granted_at: 1, expires_at: null },
    "ABC123": { tier: "premium", granted_at: 1, expires_at: null },
  }));
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  const all = storage.loadAll();
  assert.deepEqual(Object.keys(all), [PUB_A]);
});

test("loadAll filters out entries missing required fields", () => {
  const file = tmpFile();
  fs.writeFileSync(file, JSON.stringify({
    [PUB_A]: { tier: "premium", granted_at: 1, expires_at: null },
    [PUB_B]: { tier: "premium" }, // missing granted_at + expires_at
    [PUB_C]: { tier: "platinum", granted_at: 1, expires_at: null }, // invalid tier
  }));
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  const all = storage.loadAll();
  assert.deepEqual(Object.keys(all), [PUB_A]);
});

// ---------- setEntitlement ----------

test("setEntitlement creates new entry with granted_at + expires_at:null", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium", granted_by: `admin:${ADMIN_NPUB_HEX}`, note: "tester" });
  const entry = storage.getByPubkey(PUB_A);
  assert.equal(entry.tier, "premium");
  assert.equal(entry.granted_by, `admin:${ADMIN_NPUB_HEX}`);
  assert.equal(entry.note, "tester");
  assert.equal(entry.expires_at, null);
  assert.ok(typeof entry.granted_at === "number");
  assert.deepEqual(entry.devices_seen, []);
});

test("setEntitlement preserves granted_at across upsert", async () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  const firstGrantedAt = storage.getByPubkey(PUB_A).granted_at;
  await new Promise((r) => setTimeout(r, 1100));
  storage.setEntitlement(PUB_A, { tier: "premium", note: "updated" });
  const entry = storage.getByPubkey(PUB_A);
  assert.equal(entry.granted_at, firstGrantedAt, "granted_at preserved on upsert");
  assert.equal(entry.note, "updated");
});

test("setEntitlement preserves devices_seen across upsert", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  storage.recordDevice(PUB_A, "abc12345");
  storage.setEntitlement(PUB_A, { tier: "premium", note: "still tester" });
  const entry = storage.getByPubkey(PUB_A);
  assert.equal(entry.devices_seen.length, 1);
  assert.equal(entry.devices_seen[0].token_prefix, "abc12345");
});

test("setEntitlement keeps prior granted_by/note when not supplied", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium", granted_by: "admin:original", note: "original-note" });
  storage.setEntitlement(PUB_A, { tier: "premium" }); // no granted_by/note → keep prior
  const entry = storage.getByPubkey(PUB_A);
  assert.equal(entry.granted_by, "admin:original");
  assert.equal(entry.note, "original-note");
});

test("setEntitlement throws on invalid pubkey hex", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.throws(() => storage.setEntitlement("not-hex", { tier: "premium" }), /invalid_pubkey_hex/);
  assert.throws(() => storage.setEntitlement("A".repeat(64), { tier: "premium" }), /invalid_pubkey_hex/, "uppercase rejected");
  assert.throws(() => storage.setEntitlement("a".repeat(63), { tier: "premium" }), /invalid_pubkey_hex/);
});

test("setEntitlement throws on invalid tier", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.throws(() => storage.setEntitlement(PUB_A, { tier: "platinum" }), /invalid_tier/);
  assert.throws(() => storage.setEntitlement(PUB_A, {}), /invalid_tier/);
});

test("setEntitlement throws on invalid expires_at", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.throws(() => storage.setEntitlement(PUB_A, { tier: "premium", expires_at: "soon" }), /invalid_expires_at/);
});

test("setEntitlement accepts expires_at: number for time-bounded grants", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  const future = Math.floor(Date.now() / 1000) + 30 * 86400;
  storage.setEntitlement(PUB_A, { tier: "premium", expires_at: future });
  assert.equal(storage.getByPubkey(PUB_A).expires_at, future);
});

// ---------- revoke ----------

test("revoke removes entry and returns it", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium", note: "bye" });
  const removed = storage.revoke(PUB_A);
  assert.equal(removed.tier, "premium");
  assert.equal(removed.note, "bye");
  assert.equal(storage.getByPubkey(PUB_A), null);
});

test("revoke returns null for unknown pubkey", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.equal(storage.revoke(PUB_A), null);
});

// ---------- tierForPubkey ----------

test("tierForPubkey defaults to 'free' for unknown pubkey", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.equal(storage.tierForPubkey(PUB_A), "free");
});

test("tierForPubkey returns 'premium' for granted unexpired pubkey", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  assert.equal(storage.tierForPubkey(PUB_A), "premium");
});

test("tierForPubkey downgrades expired premium to 'free'", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  const past = Math.floor(Date.now() / 1000) - 86400; // 1 day ago
  storage.setEntitlement(PUB_A, { tier: "premium", expires_at: past });
  assert.equal(storage.tierForPubkey(PUB_A), "free", "expired premium reads as free");
});

test("tierForPubkey honors future expiry as 'premium'", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  const future = Math.floor(Date.now() / 1000) + 86400;
  storage.setEntitlement(PUB_A, { tier: "premium", expires_at: future });
  assert.equal(storage.tierForPubkey(PUB_A), "premium");
});

// ---------- recordDevice ----------

test("recordDevice no-ops for pubkey without entitlement (returns false)", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  // We deliberately don't auto-create entitlements from device queries —
  // free-tier pubkeys shouldn't accumulate device-tracking data.
  assert.equal(storage.recordDevice(PUB_A, "abc12345"), false);
  assert.equal(storage.getByPubkey(PUB_A), null);
});

test("recordDevice no-ops for empty/non-string tokenPrefix", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  assert.equal(storage.recordDevice(PUB_A, ""), false);
  assert.equal(storage.recordDevice(PUB_A, null), false);
  assert.equal(storage.recordDevice(PUB_A, undefined), false);
  assert.equal(storage.getByPubkey(PUB_A).devices_seen.length, 0);
});

test("recordDevice adds new device entry with timestamps", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  assert.equal(storage.recordDevice(PUB_A, "abc12345"), true);
  const entry = storage.getByPubkey(PUB_A);
  assert.equal(entry.devices_seen.length, 1);
  const dev = entry.devices_seen[0];
  assert.equal(dev.token_prefix, "abc12345");
  assert.ok(typeof dev.first_seen_at === "number");
  assert.ok(typeof dev.last_seen_at === "number");
});

test("recordDevice deduplicates by token_prefix and updates last_seen_at", async () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  storage.recordDevice(PUB_A, "abc12345");
  const firstSeen = storage.getByPubkey(PUB_A).devices_seen[0].first_seen_at;
  await new Promise((r) => setTimeout(r, 1100));
  storage.recordDevice(PUB_A, "abc12345");
  const entry = storage.getByPubkey(PUB_A);
  assert.equal(entry.devices_seen.length, 1, "no duplicate row created");
  assert.equal(entry.devices_seen[0].first_seen_at, firstSeen, "first_seen_at preserved");
  assert.ok(entry.devices_seen[0].last_seen_at > firstSeen, "last_seen_at updates");
});

test("recordDevice keeps multiple distinct device entries", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  storage.recordDevice(PUB_A, "device1a");
  storage.recordDevice(PUB_A, "device2b");
  storage.recordDevice(PUB_A, "device3c");
  assert.equal(storage.getByPubkey(PUB_A).devices_seen.length, 3);
});

// ---------- auditMultiDevice ----------

test("auditMultiDevice flags pubkeys exceeding device threshold within window", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  for (let i = 0; i < 7; i++) {
    storage.recordDevice(PUB_A, `device${i}_`);
  }
  const flagged = storage.auditMultiDevice(5, 30); // > 5 devices in last 30 days
  assert.equal(flagged.length, 1);
  assert.equal(flagged[0].pubkey, PUB_A);
  assert.equal(flagged[0].deviceCount, 7);
  assert.equal(flagged[0].tier, "premium");
});

test("auditMultiDevice excludes devices outside window", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  // Manually inject old + recent devices.
  const ageOld = Math.floor(Date.now() / 1000) - 60 * 86400; // 60 days ago
  const ageNew = Math.floor(Date.now() / 1000) - 1 * 86400;  // 1 day ago
  const all = storage.loadAll();
  all[PUB_A].devices_seen = [
    { token_prefix: "old1", first_seen_at: ageOld, last_seen_at: ageOld },
    { token_prefix: "old2", first_seen_at: ageOld, last_seen_at: ageOld },
    { token_prefix: "old3", first_seen_at: ageOld, last_seen_at: ageOld },
    { token_prefix: "old4", first_seen_at: ageOld, last_seen_at: ageOld },
    { token_prefix: "old5", first_seen_at: ageOld, last_seen_at: ageOld },
    { token_prefix: "old6", first_seen_at: ageOld, last_seen_at: ageOld },
    { token_prefix: "newR", first_seen_at: ageNew, last_seen_at: ageNew },
  ];
  fs.writeFileSync(file, JSON.stringify(all, null, 2));
  // Within 30 days, only "newR" counts → 1 device → does NOT exceed threshold 5
  assert.equal(storage.auditMultiDevice(5, 30).length, 0);
  // Within 90 days, all 7 count → exceeds threshold 5
  assert.equal(storage.auditMultiDevice(5, 90).length, 1);
});

test("auditMultiDevice returns empty array when nothing flagged", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  storage.recordDevice(PUB_A, "abc12345");
  assert.deepEqual(storage.auditMultiDevice(5, 30), []);
});

// ---------- listByTier ----------

test("listByTier returns entries matching tier, including pubkey", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium", note: "tester1" });
  storage.setEntitlement(PUB_B, { tier: "premium", note: "tester2" });
  storage.setEntitlement(PUB_C, { tier: "free" });
  const premium = storage.listByTier("premium");
  assert.equal(premium.length, 2);
  assert.ok(premium.some((e) => e.pubkey === PUB_A && e.note === "tester1"));
  assert.ok(premium.some((e) => e.pubkey === PUB_B && e.note === "tester2"));
});

test("listByTier treats expired premium as free for filtering", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  const past = Math.floor(Date.now() / 1000) - 86400;
  storage.setEntitlement(PUB_A, { tier: "premium" });            // active
  storage.setEntitlement(PUB_B, { tier: "premium", expires_at: past }); // expired
  const premium = storage.listByTier("premium");
  assert.equal(premium.length, 1);
  assert.equal(premium[0].pubkey, PUB_A);
});

// ---------- maxAccountsForTier / maxClientsForTier ----------

test("maxAccountsForTier returns 4 for free, 10 for premium", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.equal(storage.maxAccountsForTier("free"), 4);
  assert.equal(storage.maxAccountsForTier("premium"), 10);
});

test("maxClientsForTier returns 5 for free, 30 for premium", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  assert.equal(storage.maxClientsForTier("free"), 5);
  assert.equal(storage.maxClientsForTier("premium"), 30);
});

// ---------- atomic write durability ----------

test("atomic write: temp file is cleaned up after rename", () => {
  const file = tmpFile();
  const { createEntitlementsStorage } = require("../entitlements");
  const storage = createEntitlementsStorage(file);
  storage.setEntitlement(PUB_A, { tier: "premium" });
  assert.ok(!fs.existsSync(file + ".tmp"), "temp file should not remain after write");
  assert.ok(fs.existsSync(file), "target file should exist");
});
