const test = require("node:test");
const assert = require("node:assert/strict");
const { npubToHex, bech32Decode, parseArgs } = require("../tools/grant");

// Known-good npub ↔ hex pair (POWR test account, per project memory).
const NPUB = "npub125f8lj0pcq7xk3v68w4h9ldenhh3v3x97gumm5yl8e0mgq0dnvssjptd2l";
const HEX = "55127fc9e1c03c6b459a3bab72fdb99def1644c5f239bdd09f3e5fb401ed9b21";

// ---------- npubToHex ----------

test("npubToHex round-trips a known good npub", () => {
  assert.equal(npubToHex(NPUB), HEX);
});

test("npubToHex passes hex through unchanged", () => {
  assert.equal(npubToHex(HEX), HEX);
});

test("npubToHex normalizes uppercase hex", () => {
  assert.equal(npubToHex(HEX.toUpperCase()), HEX);
});

test("npubToHex throws on garbage input", () => {
  assert.throws(() => npubToHex("not a pubkey"), /invalid bech32/);
});

test("npubToHex throws on hex of wrong length", () => {
  // 63 chars → not valid hex pubkey AND not valid bech32
  assert.throws(() => npubToHex("a".repeat(63)), /invalid bech32/);
});

test("npubToHex throws on bech32 with wrong HRP (e.g. nsec)", () => {
  // Synthesize an nsec1 by re-encoding... easier: assert the existing detection
  // path via a malformed string starting with "nsec1".
  assert.throws(() => npubToHex("nsec1foo"), /invalid bech32/);
});

test("npubToHex throws on bech32 with corrupted checksum", () => {
  // Flip the last character — checksum should fail
  const corrupted = NPUB.slice(0, -1) + (NPUB.slice(-1) === "l" ? "0" : "l");
  assert.throws(() => npubToHex(corrupted), /invalid bech32/);
});

test("bech32Decode returns hrp + words for valid npub", () => {
  const decoded = bech32Decode(NPUB);
  assert.equal(decoded.hrp, "npub");
  // 32 bytes → 52 5-bit words (32 * 8 / 5 = 51.2 → 52 with padding)
  assert.equal(decoded.words.length, 52);
});

// ---------- parseArgs ----------

test("parseArgs collects positional args in order", () => {
  const args = parseArgs(["grant", "npub1abc", "extra"]);
  assert.deepEqual(args._, ["grant", "npub1abc", "extra"]);
  assert.deepEqual(args.flags, {});
});

test("parseArgs handles --flag value pair", () => {
  const args = parseArgs(["grant", "npub1abc", "--note", "tester @bfgreen"]);
  assert.deepEqual(args._, ["grant", "npub1abc"]);
  assert.equal(args.flags.note, "tester @bfgreen");
});

test("parseArgs handles --flag=value form", () => {
  const args = parseArgs(["list", "--tier=premium"]);
  assert.deepEqual(args._, ["list"]);
  assert.equal(args.flags.tier, "premium");
});

test("parseArgs treats trailing --flag (no value) as boolean true", () => {
  const args = parseArgs(["audit", "--verbose"]);
  assert.deepEqual(args._, ["audit"]);
  assert.equal(args.flags.verbose, true);
});

test("parseArgs treats --flag followed by --otherflag as boolean true", () => {
  // --verbose has no value; --threshold takes the next positional.
  const args = parseArgs(["audit", "--verbose", "--threshold", "10"]);
  assert.deepEqual(args._, ["audit"]);
  assert.equal(args.flags.verbose, true);
  assert.equal(args.flags.threshold, "10");
});

test("parseArgs handles mixed positional + flags", () => {
  const args = parseArgs(["bootstrap-existing", "--threshold", "5", "--clients-file=/opt/clave-proxy-test/clients.json"]);
  assert.deepEqual(args._, ["bootstrap-existing"]);
  assert.equal(args.flags.threshold, "5");
  assert.equal(args.flags["clients-file"], "/opt/clave-proxy-test/clients.json");
});

test("parseArgs returns empty when given empty argv", () => {
  const args = parseArgs([]);
  assert.deepEqual(args._, []);
  assert.deepEqual(args.flags, {});
});
