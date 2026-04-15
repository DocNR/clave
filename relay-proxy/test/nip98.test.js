const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { schnorr } = require("@noble/curves/secp256k1.js");
const { parseAuthHeader, verifyNip98, sha256Hex } = require("../nip98");

// Helper: synthesize a valid NIP-98 event signed with a known test key
async function makeSignedEvent({ url, method, body, createdAt, privKey }) {
  const pubkey = Buffer.from(schnorr.getPublicKey(privKey)).toString("hex");
  const ts = createdAt ?? Math.floor(Date.now() / 1000);
  const tags = [
    ["u", url],
    ["method", method],
  ];
  if (body) {
    tags.push(["payload", sha256Hex(Buffer.from(body))]);
  }
  const serialized = JSON.stringify([0, pubkey, ts, 27235, tags, ""]);
  const id = crypto.createHash("sha256").update(serialized).digest();
  const sig = Buffer.from(await schnorr.sign(id, privKey)).toString("hex");
  return {
    id: id.toString("hex"),
    pubkey,
    created_at: ts,
    kind: 27235,
    tags,
    content: "",
    sig,
  };
}

function encodeHeader(event) {
  return "Nostr " + Buffer.from(JSON.stringify(event)).toString("base64");
}

test("parseAuthHeader extracts the event from a valid header", () => {
  const event = { kind: 27235, foo: "bar" };
  const header = encodeHeader(event);
  const parsed = parseAuthHeader(header);
  assert.equal(parsed.kind, 27235);
  assert.equal(parsed.foo, "bar");
});

test("parseAuthHeader rejects missing Nostr scheme", () => {
  assert.throws(() => parseAuthHeader("Bearer abc"), /scheme/i);
});

test("parseAuthHeader rejects malformed base64", () => {
  assert.throws(() => parseAuthHeader("Nostr !!!"), /parse/i);
});

test("verifyNip98 accepts a fresh, correctly-signed event", async () => {
  const privKey = crypto.randomBytes(32);
  const url = "https://proxy.clave.casa/register";
  const method = "POST";
  const body = JSON.stringify({ token: "abc123" });
  const event = await makeSignedEvent({ url, method, body, privKey });

  const result = await verifyNip98(event, url, method, sha256Hex(Buffer.from(body)));
  assert.equal(result.valid, true);
  assert.equal(result.pubkey, event.pubkey);
});

test("verifyNip98 rejects wrong kind", async () => {
  const privKey = crypto.randomBytes(32);
  const event = await makeSignedEvent({
    url: "https://proxy.clave.casa/register",
    method: "POST",
    privKey,
  });
  event.kind = 1; // wrong kind
  const result = await verifyNip98(event, "https://proxy.clave.casa/register", "POST");
  assert.equal(result.valid, false);
  assert.match(result.error, /kind/i);
});

test("verifyNip98 rejects stale timestamp (>60s old)", async () => {
  const privKey = crypto.randomBytes(32);
  const url = "https://proxy.clave.casa/register";
  const event = await makeSignedEvent({
    url,
    method: "POST",
    createdAt: Math.floor(Date.now() / 1000) - 120,
    privKey,
  });
  const result = await verifyNip98(event, url, "POST");
  assert.equal(result.valid, false);
  assert.match(result.error, /timestamp/i);
});

test("verifyNip98 rejects wrong URL", async () => {
  const privKey = crypto.randomBytes(32);
  const event = await makeSignedEvent({
    url: "https://proxy.clave.casa/register",
    method: "POST",
    privKey,
  });
  const result = await verifyNip98(event, "https://proxy.clave.casa/unregister", "POST");
  assert.equal(result.valid, false);
  assert.match(result.error, /url/i);
});

test("verifyNip98 rejects wrong method", async () => {
  const privKey = crypto.randomBytes(32);
  const url = "https://proxy.clave.casa/register";
  const event = await makeSignedEvent({ url, method: "POST", privKey });
  const result = await verifyNip98(event, url, "GET");
  assert.equal(result.valid, false);
  assert.match(result.error, /method/i);
});

test("verifyNip98 rejects mismatched payload hash", async () => {
  const privKey = crypto.randomBytes(32);
  const url = "https://proxy.clave.casa/register";
  const body = JSON.stringify({ token: "abc" });
  const event = await makeSignedEvent({ url, method: "POST", body, privKey });
  // Verify with different body
  const result = await verifyNip98(event, url, "POST", sha256Hex(Buffer.from("different")));
  assert.equal(result.valid, false);
  assert.match(result.error, /payload/i);
});

test("verifyNip98 rejects tampered signature", async () => {
  const privKey = crypto.randomBytes(32);
  const url = "https://proxy.clave.casa/register";
  const event = await makeSignedEvent({ url, method: "POST", privKey });
  event.sig = "00".repeat(64); // tamper
  const result = await verifyNip98(event, url, "POST");
  assert.equal(result.valid, false);
  assert.match(result.error, /signature/i);
});

test("sha256Hex produces a 64-char hex string", () => {
  const hash = sha256Hex(Buffer.from("hello"));
  assert.equal(hash.length, 64);
  assert.equal(hash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
});
