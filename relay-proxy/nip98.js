const crypto = require("node:crypto");
const { schnorr } = require("@noble/curves/secp256k1.js");

const NIP98_KIND = 27235;
const MAX_AGE_SECONDS = 60;

function sha256Hex(buf) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function parseAuthHeader(header) {
  if (typeof header !== "string" || !header.startsWith("Nostr ")) {
    throw new Error("Invalid Authorization scheme — expected 'Nostr <base64>'");
  }
  const b64 = header.slice("Nostr ".length).trim();
  let json;
  try {
    json = Buffer.from(b64, "base64").toString("utf8");
  } catch {
    throw new Error("Failed to parse base64-encoded auth header");
  }
  let event;
  try {
    event = JSON.parse(json);
  } catch {
    throw new Error("Failed to parse auth event JSON");
  }
  return event;
}

async function verifyNip98(event, expectedUrl, expectedMethod, expectedPayloadHash) {
  if (!event || typeof event !== "object") {
    return { valid: false, error: "Event is not an object" };
  }

  if (event.kind !== NIP98_KIND) {
    return { valid: false, error: `Wrong kind: expected ${NIP98_KIND}, got ${event.kind}` };
  }

  const now = Math.floor(Date.now() / 1000);
  const age = Math.abs(now - event.created_at);
  if (age > MAX_AGE_SECONDS) {
    return { valid: false, error: `Stale timestamp: ${age}s old (max ${MAX_AGE_SECONDS}s)` };
  }

  const tags = event.tags || [];
  const uTag = tags.find((t) => t[0] === "u");
  const methodTag = tags.find((t) => t[0] === "method");
  const payloadTag = tags.find((t) => t[0] === "payload");

  if (!uTag || uTag[1] !== expectedUrl) {
    return { valid: false, error: `URL mismatch: expected ${expectedUrl}, got ${uTag?.[1]}` };
  }

  if (!methodTag || methodTag[1] !== expectedMethod) {
    return { valid: false, error: `Method mismatch: expected ${expectedMethod}, got ${methodTag?.[1]}` };
  }

  if (expectedPayloadHash) {
    if (!payloadTag || payloadTag[1] !== expectedPayloadHash) {
      return {
        valid: false,
        error: `Payload hash mismatch: expected ${expectedPayloadHash}, got ${payloadTag?.[1]}`,
      };
    }
  }

  // Recompute event id and verify signature
  const serialized = JSON.stringify([
    0,
    event.pubkey,
    event.created_at,
    event.kind,
    tags,
    event.content ?? "",
  ]);
  const idHash = crypto.createHash("sha256").update(serialized).digest();
  const computedId = idHash.toString("hex");

  if (computedId !== event.id) {
    return { valid: false, error: "Event id does not match content hash" };
  }

  try {
    const ok = await schnorr.verify(
      Buffer.from(event.sig, "hex"),
      idHash,
      Buffer.from(event.pubkey, "hex")
    );
    if (!ok) {
      return { valid: false, error: "Invalid Schnorr signature" };
    }
  } catch (e) {
    return { valid: false, error: `Signature verification threw: ${e.message}` };
  }

  return { valid: true, pubkey: event.pubkey };
}

module.exports = { parseAuthHeader, verifyNip98, sha256Hex };
