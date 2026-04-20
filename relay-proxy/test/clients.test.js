const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

function tmpFile() {
  return path.join(os.tmpdir(), `clave-clients-test-${Date.now()}-${Math.random()}.json`);
}

test("loadAll returns empty array when file doesn't exist", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  assert.deepEqual(storage.loadAll(), []);
});

test("addPair adds a new entry with timestamps", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: ["wss://a", "wss://b"] });
  const all = storage.loadAll();
  assert.equal(all.length, 1);
  assert.equal(all[0].signerPubkey, "s1");
  assert.equal(all[0].clientPubkey, "c1");
  assert.deepEqual(all[0].relayUrls, ["wss://a", "wss://b"]);
  assert.ok(typeof all[0].createdAt === "number");
  assert.ok(typeof all[0].lastSeenAt === "number");
});

test("addPair is idempotent — upserts relayUrls + lastSeenAt on (signer, client) match", async () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: ["wss://a"] });
  const firstCreated = storage.loadAll()[0].createdAt;
  await new Promise((r) => setTimeout(r, 1100));
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: ["wss://x", "wss://y"] });
  const all = storage.loadAll();
  assert.equal(all.length, 1);
  assert.deepEqual(all[0].relayUrls, ["wss://x", "wss://y"]);
  assert.equal(all[0].createdAt, firstCreated, "createdAt is preserved on upsert");
  assert.ok(all[0].lastSeenAt > firstCreated, "lastSeenAt updates on upsert");
});

test("addPair with different clientPubkey creates separate entry", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: ["wss://a"] });
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c2", relayUrls: ["wss://b"] });
  assert.equal(storage.loadAll().length, 2);
});

test("removePair removes matching entry and returns it", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: ["wss://a"] });
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c2", relayUrls: ["wss://b"] });
  const removed = storage.removePair({ signerPubkey: "s1", clientPubkey: "c1" });
  assert.equal(removed.clientPubkey, "c1");
  const remaining = storage.loadAll();
  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].clientPubkey, "c2");
});

test("removePair returns null when no match", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  const result = storage.removePair({ signerPubkey: "nope", clientPubkey: "nope" });
  assert.equal(result, null);
});

test("removeBySigner removes all entries for a signer and returns them", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: ["wss://a"] });
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c2", relayUrls: ["wss://b"] });
  storage.addPair({ signerPubkey: "s2", clientPubkey: "c1", relayUrls: ["wss://c"] });
  const removed = storage.removeBySigner("s1");
  assert.equal(removed.length, 2);
  const remaining = storage.loadAll();
  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].signerPubkey, "s2");
});

test("countBySigner returns 0 for unknown signer", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  assert.equal(storage.countBySigner("nope"), 0);
});

test("countBySigner returns correct count per signer", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: [] });
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c2", relayUrls: [] });
  storage.addPair({ signerPubkey: "s2", clientPubkey: "c1", relayUrls: [] });
  assert.equal(storage.countBySigner("s1"), 2);
  assert.equal(storage.countBySigner("s2"), 1);
});

test("loadAll ignores malformed JSON", () => {
  const file = tmpFile();
  fs.writeFileSync(file, "not json {{{");
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  assert.deepEqual(storage.loadAll(), []);
});

test("loadAll filters out entries missing required fields", () => {
  const file = tmpFile();
  fs.writeFileSync(file, JSON.stringify([
    { signerPubkey: "s1", clientPubkey: "c1", relayUrls: [], createdAt: 1, lastSeenAt: 1 },
    { signerPubkey: "incomplete" },
  ]));
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  assert.equal(storage.loadAll().length, 1);
});

test("atomic write: temp file is cleaned up after rename", () => {
  const file = tmpFile();
  const { createClientsStorage } = require("../clients");
  const storage = createClientsStorage(file);
  storage.addPair({ signerPubkey: "s1", clientPubkey: "c1", relayUrls: [] });
  assert.ok(!fs.existsSync(file + ".tmp"), "temp file should not remain after write");
  assert.ok(fs.existsSync(file), "target file should exist");
});
