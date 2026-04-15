const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

// Use a temp file per test so they don't pollute each other
function tmpFile() {
  return path.join(os.tmpdir(), `clave-storage-test-${Date.now()}-${Math.random()}.json`);
}

test("loadTokens returns empty array when file doesn't exist", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  assert.deepEqual(storage.loadTokens(), []);
});

test("upsertToken adds a new entry", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  const all = storage.loadTokens();
  assert.equal(all.length, 1);
  assert.equal(all[0].token, "t1");
  assert.equal(all[0].pubkey, "p1");
  assert.ok(typeof all[0].last_seen === "number");
});

test("upsertToken deduplicates by (token, pubkey)", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  assert.equal(storage.loadTokens().length, 1);
});

test("upsertToken with different pubkey creates separate entry", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  storage.upsertToken({ token: "t1", pubkey: "p2" });
  assert.equal(storage.loadTokens().length, 2);
});

test("upsertToken updates last_seen on dedupe", async () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  const firstSeen = storage.loadTokens()[0].last_seen;
  await new Promise((r) => setTimeout(r, 1100));
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  const secondSeen = storage.loadTokens()[0].last_seen;
  assert.ok(secondSeen > firstSeen);
});

test("removeToken removes matching (token, pubkey) only", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  storage.upsertToken({ token: "t1", pubkey: "p2" });
  storage.removeToken({ token: "t1", pubkey: "p1" });
  const remaining = storage.loadTokens();
  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].pubkey, "p2");
});

test("findByPubkey returns all tokens for a pubkey", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  storage.upsertToken({ token: "t2", pubkey: "p1" });
  storage.upsertToken({ token: "t3", pubkey: "p2" });
  const matches = storage.findByPubkey("p1");
  assert.equal(matches.length, 2);
  assert.ok(matches.every((m) => m.pubkey === "p1"));
});

test("findByPubkey returns empty array when nothing matches", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  storage.upsertToken({ token: "t1", pubkey: "p1" });
  assert.deepEqual(storage.findByPubkey("nope"), []);
});

test("migrateIfLegacy detects flat string array and wipes it", () => {
  const file = tmpFile();
  fs.writeFileSync(file, JSON.stringify(["legacytoken1", "legacytoken2"]));
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  const result = storage.migrateIfLegacy();
  assert.equal(result.migrated, true);
  assert.equal(result.legacyCount, 2);
  assert.deepEqual(storage.loadTokens(), []);
  // Backup file should exist
  assert.ok(fs.existsSync(file + ".legacy-backup"));
  // Cleanup
  fs.unlinkSync(file + ".legacy-backup");
});

test("migrateIfLegacy is a no-op when file is already new format", () => {
  const file = tmpFile();
  fs.writeFileSync(
    file,
    JSON.stringify([{ token: "t1", pubkey: "p1", last_seen: 12345 }])
  );
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  const result = storage.migrateIfLegacy();
  assert.equal(result.migrated, false);
  assert.equal(storage.loadTokens().length, 1);
});

test("migrateIfLegacy is a no-op when file doesn't exist", () => {
  const file = tmpFile();
  const { createStorage } = require("../storage");
  const storage = createStorage(file);
  const result = storage.migrateIfLegacy();
  assert.equal(result.migrated, false);
});
