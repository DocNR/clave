#!/usr/bin/env node
//
// grant.js — admin CLI for entitlements.json
//
// Phase 1 manual-grant tool for the premium-tier system. Edits
// /opt/clave-proxy-test/entitlements.json (or wherever ENTITLEMENTS_FILE
// points) directly using the entitlements.js factory module.
//
// Run on Dell as a user that can write entitlements.json:
//   sudo -u clave-proxy node tools/grant.js grant <npub>
//
// or:
//   sudo node tools/grant.js grant <npub>   # then chown back if needed
//
// Subcommands:
//   grant <npub|hex> [--note "..."] [--by "<admin_npub|hex>"] [--expires-at <unix>]
//   revoke <npub|hex>
//   list [--tier free|premium]
//   audit [--threshold N] [--days D]   (default: 5 distinct devices over 30d)
//   bootstrap-existing [--clients-file <path>] [--threshold N]   (default 3)
//   help
//
// All subcommands accept --file <path> to override the entitlements file.
// Default: ./entitlements.json (cwd-relative, matches proxy.js).
//
// Phase 2 (Lightning) reuses the same data file via a different writer
// path (HTTP endpoint) — this CLI keeps working alongside it.

const fs = require("node:fs");
const path = require("node:path");
const { createEntitlementsStorage } = require("../entitlements");

// ---------- bech32 (NIP-19 npub) ----------

const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
const BECH32_GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

function bech32Polymod(values) {
  let chk = 1;
  for (const v of values) {
    const top = chk >>> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) {
      if ((top >>> i) & 1) chk ^= BECH32_GEN[i];
    }
  }
  return chk >>> 0;
}

function bech32HrpExpand(hrp) {
  const out = [];
  for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >>> 5);
  out.push(0);
  for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) & 31);
  return out;
}

function bech32VerifyChecksum(hrp, data) {
  return bech32Polymod([...bech32HrpExpand(hrp), ...data]) === 1;
}

function bech32Decode(s) {
  if (typeof s !== "string" || s.length < 8 || s.length > 200) {
    throw new Error("invalid bech32: length");
  }
  if (s.toLowerCase() !== s && s.toUpperCase() !== s) {
    throw new Error("invalid bech32: mixed case");
  }
  const lower = s.toLowerCase();
  const sep = lower.lastIndexOf("1");
  if (sep < 1 || sep + 7 > lower.length) {
    throw new Error("invalid bech32: separator");
  }
  const hrp = lower.slice(0, sep);
  const data = [];
  for (let i = sep + 1; i < lower.length; i++) {
    const idx = BECH32_CHARSET.indexOf(lower[i]);
    if (idx < 0) throw new Error("invalid bech32: char " + lower[i]);
    data.push(idx);
  }
  if (!bech32VerifyChecksum(hrp, data)) {
    throw new Error("invalid bech32: checksum");
  }
  return { hrp, words: data.slice(0, -6) };
}

function bech32WordsToBytes(words) {
  let acc = 0;
  let bits = 0;
  const out = [];
  for (const w of words) {
    if (w < 0 || w > 31) throw new Error("invalid 5-bit word");
    acc = (acc << 5) | w;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.push((acc >>> bits) & 0xff);
    }
  }
  if (bits >= 5 || ((acc << (8 - bits)) & 0xff)) {
    throw new Error("invalid 5-bit padding");
  }
  return Buffer.from(out);
}

function npubToHex(input) {
  // Pass-through if already hex
  if (/^[0-9a-f]{64}$/.test(input)) return input;
  if (/^[0-9A-F]{64}$/.test(input)) return input.toLowerCase();
  // Bech32 npub
  const decoded = bech32Decode(input);
  if (decoded.hrp !== "npub") {
    throw new Error(`expected npub bech32, got hrp="${decoded.hrp}"`);
  }
  const bytes = bech32WordsToBytes(decoded.words);
  if (bytes.length !== 32) {
    throw new Error(`expected 32-byte pubkey, got ${bytes.length}`);
  }
  return bytes.toString("hex");
}

function shortPubkey(hex) {
  return `${hex.slice(0, 8)}...${hex.slice(-4)}`;
}

// ---------- argv parsing ----------

function parseArgs(argv) {
  const args = { _: [], flags: {} };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      if (eq > 0) {
        args.flags[a.slice(2, eq)] = a.slice(eq + 1);
      } else {
        const next = argv[i + 1];
        if (next !== undefined && !next.startsWith("--")) {
          args.flags[a.slice(2)] = next;
          i++;
        } else {
          args.flags[a.slice(2)] = true;
        }
      }
    } else {
      args._.push(a);
    }
  }
  return args;
}

// ---------- subcommands ----------

function cmdGrant(storage, args) {
  const target = args._[1];
  if (!target) {
    throw new Error("usage: grant <npub|hex> [--note '...'] [--by '<npub|hex>'] [--expires-at <unix>]");
  }
  const targetHex = npubToHex(target);
  const note = args.flags.note;
  const expiresAtFlag = args.flags["expires-at"];
  let expiresAt = null;
  if (expiresAtFlag !== undefined && expiresAtFlag !== true) {
    expiresAt = Number(expiresAtFlag);
    if (!Number.isFinite(expiresAt)) throw new Error("--expires-at must be a unix timestamp (seconds)");
  }
  let grantedBy = "admin:cli";
  if (args.flags.by) {
    const byHex = npubToHex(args.flags.by);
    grantedBy = `admin:${byHex}`;
  }
  const fields = { tier: "premium", granted_by: grantedBy, expires_at: expiresAt };
  if (note) fields.note = note;
  const result = storage.setEntitlement(targetHex, fields);
  console.log(`granted premium to ${shortPubkey(targetHex)}`);
  console.log(`  granted_at: ${new Date(result.granted_at * 1000).toISOString()}`);
  console.log(`  granted_by: ${result.granted_by}`);
  if (result.note) console.log(`  note:       ${result.note}`);
  if (result.expires_at !== null) {
    console.log(`  expires_at: ${new Date(result.expires_at * 1000).toISOString()}`);
  } else {
    console.log(`  expires_at: never`);
  }
}

function cmdRevoke(storage, args) {
  const target = args._[1];
  if (!target) throw new Error("usage: revoke <npub|hex>");
  const targetHex = npubToHex(target);
  const removed = storage.revoke(targetHex);
  if (!removed) {
    console.log(`no entitlement entry for ${shortPubkey(targetHex)} (already free)`);
    return;
  }
  console.log(`revoked ${removed.tier} from ${shortPubkey(targetHex)}`);
  if (removed.note) console.log(`  was-note: ${removed.note}`);
  if (removed.granted_by) console.log(`  was-granted-by: ${removed.granted_by}`);
}

function cmdList(storage, args) {
  const tierFilter = args.flags.tier;
  if (tierFilter && tierFilter !== "free" && tierFilter !== "premium") {
    throw new Error("--tier must be 'free' or 'premium'");
  }
  const all = storage.loadAll();
  const rows = Object.entries(all).map(([pubkey, entry]) => {
    const effectiveTier = storage.tierForPubkey(pubkey);
    return { pubkey, entry, effectiveTier };
  });
  const filtered = tierFilter ? rows.filter((r) => r.effectiveTier === tierFilter) : rows;
  if (filtered.length === 0) {
    console.log(tierFilter ? `no entries with tier=${tierFilter}` : "no entitlement entries");
    return;
  }
  console.log(`${filtered.length} entitlement entr${filtered.length === 1 ? "y" : "ies"}:`);
  for (const { pubkey, entry, effectiveTier } of filtered) {
    const exp = entry.expires_at === null
      ? "lifetime"
      : entry.expires_at <= Math.floor(Date.now() / 1000)
        ? "EXPIRED"
        : new Date(entry.expires_at * 1000).toISOString();
    const devices = Array.isArray(entry.devices_seen) ? entry.devices_seen.length : 0;
    console.log(
      `  ${pubkey}  ${entry.tier.padEnd(8)} effective=${effectiveTier.padEnd(8)}  ` +
      `granted=${new Date(entry.granted_at * 1000).toISOString()}  expires=${exp}  ` +
      `devices=${devices}` + (entry.note ? `  note="${entry.note}"` : "")
    );
  }
}

function cmdAudit(storage, args) {
  const threshold = Number(args.flags.threshold ?? 5);
  const days = Number(args.flags.days ?? 30);
  if (!Number.isFinite(threshold) || threshold < 1) throw new Error("--threshold must be a positive integer");
  if (!Number.isFinite(days) || days < 1) throw new Error("--days must be a positive integer");
  const flagged = storage.auditMultiDevice(threshold, days);
  if (flagged.length === 0) {
    console.log(`no pubkeys exceed ${threshold} distinct devices in the past ${days}d`);
    return;
  }
  console.log(`${flagged.length} flagged: > ${threshold} distinct devices in past ${days}d`);
  for (const f of flagged) {
    console.log(`  ${f.pubkey}  tier=${f.tier}  devices=${f.deviceCount}`);
  }
}

function cmdBootstrapExisting(storage, args) {
  const clientsFile = args.flags["clients-file"] || "./clients.json";
  const threshold = Number(args.flags.threshold ?? 3);
  if (!Number.isFinite(threshold) || threshold < 1) throw new Error("--threshold must be a positive integer");
  if (!fs.existsSync(clientsFile)) {
    throw new Error(`clients file not found: ${path.resolve(clientsFile)}`);
  }
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(clientsFile, "utf8"));
  } catch (e) {
    throw new Error(`failed to parse clients file: ${e.message}`);
  }
  if (!Array.isArray(raw)) throw new Error("clients file must be an array of pair entries");

  // Count pairs per signer.
  const pairCount = new Map();
  for (const p of raw) {
    if (!p || typeof p.signerPubkey !== "string") continue;
    pairCount.set(p.signerPubkey, (pairCount.get(p.signerPubkey) || 0) + 1);
  }

  const candidates = [...pairCount.entries()].filter(([, n]) => n >= threshold);
  if (candidates.length === 0) {
    console.log(`no signers in ${clientsFile} have ≥${threshold} paired clients`);
    return;
  }

  console.log(`bootstrap-existing: ${candidates.length} candidate(s) from ${clientsFile} (≥${threshold} pairs)`);
  let granted = 0;
  let alreadyPremium = 0;
  for (const [pubkey, count] of candidates) {
    const existing = storage.getByPubkey(pubkey);
    if (existing && existing.tier === "premium") {
      console.log(`  skip ${shortPubkey(pubkey)}  pairs=${count}  already premium`);
      alreadyPremium++;
      continue;
    }
    storage.setEntitlement(pubkey, {
      tier: "premium",
      granted_by: "admin:bootstrap-existing",
      note: `auto-grant @ ${count} paired clients`,
    });
    console.log(`  grant ${shortPubkey(pubkey)}  pairs=${count}  → premium`);
    granted++;
  }
  console.log(`done. granted=${granted}  already-premium=${alreadyPremium}`);
}

function cmdHelp() {
  console.log(`grant.js — admin CLI for entitlements.json

Usage:
  node tools/grant.js [--file <path>] <subcommand> [args]

Subcommands:
  grant <npub|hex> [--note "..."] [--by "<npub|hex>"] [--expires-at <unix>]
      Grant premium tier to the pubkey. Preserves granted_at + devices_seen
      on upsert. expires_at defaults to null (lifetime).

  revoke <npub|hex>
      Remove the entitlement entry. Caller falls back to free tier on next
      query (subject to iOS cache TTL).

  list [--tier free|premium]
      List all entitlement entries (or just one tier). Shows effective tier
      so expired premium reads as 'free'.

  audit [--threshold N] [--days D]
      Print pubkeys exceeding N distinct devices in the past D days.
      Defaults: threshold=5, days=30.

  bootstrap-existing [--clients-file <path>] [--threshold N]
      Read clients.json, grant premium to every signer with ≥N paired clients.
      Defaults: clients-file=./clients.json, threshold=3.
      Idempotent — skips already-premium signers.

  help
      This message.

Global flag:
  --file <path>   Override entitlements.json path. Default: ./entitlements.json

Run as a user that can write entitlements.json:
  sudo -u clave-proxy node tools/grant.js grant npub1...
`);
}

// ---------- main ----------

function main() {
  const args = parseArgs(process.argv.slice(2));
  const sub = args._[0] || "help";
  if (sub === "help" || sub === "--help" || sub === "-h") {
    cmdHelp();
    return 0;
  }

  const filePath = args.flags.file || "./entitlements.json";
  const storage = createEntitlementsStorage(filePath);

  try {
    switch (sub) {
      case "grant":
        cmdGrant(storage, args);
        break;
      case "revoke":
        cmdRevoke(storage, args);
        break;
      case "list":
        cmdList(storage, args);
        break;
      case "audit":
        cmdAudit(storage, args);
        break;
      case "bootstrap-existing":
        cmdBootstrapExisting(storage, args);
        break;
      default:
        console.error(`unknown subcommand: ${sub}`);
        cmdHelp();
        return 2;
    }
    return 0;
  } catch (e) {
    console.error(`error: ${e.message}`);
    return 1;
  }
}

if (require.main === module) {
  process.exit(main());
}

module.exports = { npubToHex, bech32Decode, parseArgs };
