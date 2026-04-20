const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

// Minimal in-process fake WebSocket — mimics the subset of `ws` API the pool uses.
function makeFakeSocket() {
  const ws = new EventEmitter();
  ws.readyState = 0; // CONNECTING
  ws.sent = [];
  ws.pingCount = 0;
  ws.terminated = false;
  ws.send = (msg) => ws.sent.push(msg);
  ws.ping = () => { ws.pingCount++; };
  ws.close = () => {
    ws.readyState = 3; // CLOSED
    ws.emit("close");
  };
  ws.terminate = () => {
    ws.readyState = 3;
    ws.terminated = true;
    ws.emit("close");
  };
  // Helper for tests — simulate the server side opening the socket
  ws._openFromServer = () => {
    ws.readyState = 1; // OPEN
    ws.emit("open");
  };
  return ws;
}

function makeFactory() {
  const sockets = [];
  const factory = (url) => {
    const ws = makeFakeSocket();
    ws._url = url;
    sockets.push(ws);
    return ws;
  };
  factory.sockets = sockets;
  return factory;
}

test("addRelay opens one WebSocket on first ref", () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({ createSocket: factory, signerPubkeysProvider: () => ["s1"] });
  pool.addRelay("wss://a");
  assert.equal(factory.sockets.length, 1);
  assert.equal(factory.sockets[0]._url, "wss://a");
});

test("addRelay on same URL bumps refcount without opening another WS", () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({ createSocket: factory, signerPubkeysProvider: () => ["s1"] });
  pool.addRelay("wss://a");
  pool.addRelay("wss://a");
  assert.equal(factory.sockets.length, 1);
  assert.equal(pool.getState("wss://a").refCount, 2);
});

test("releaseRelay decrements refcount; does not close until refs hit 0", () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({ createSocket: factory, signerPubkeysProvider: () => ["s1"] });
  pool.addRelay("wss://a");
  pool.addRelay("wss://a");
  pool.releaseRelay("wss://a");
  assert.equal(pool.getState("wss://a").refCount, 1);
  assert.notEqual(factory.sockets[0].readyState, 3, "should still be open");
});

test("releaseRelay closes WS when refcount reaches 0", () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({ createSocket: factory, signerPubkeysProvider: () => ["s1"] });
  pool.addRelay("wss://a");
  pool.releaseRelay("wss://a");
  assert.equal(factory.sockets[0].readyState, 3, "WS should be closed");
  assert.equal(pool.getState("wss://a"), null, "entry should be removed");
});

test("releaseRelay on unknown URL is a no-op", () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({ createSocket: factory, signerPubkeysProvider: () => ["s1"] });
  pool.releaseRelay("wss://never-added");
  assert.equal(factory.sockets.length, 0);
});

test("on WS open, sends narrow REQ with kinds:[24133] + #p filter", () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1", "s2"],
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  assert.equal(factory.sockets[0].sent.length, 1);
  const [verb, subId, filter] = JSON.parse(factory.sockets[0].sent[0]);
  assert.equal(verb, "REQ");
  assert.equal(subId, "clave-watch");
  assert.deepEqual(filter.kinds, [24133]);
  assert.deepEqual(filter["#p"], ["s1", "s2"]);
  assert.ok(typeof filter.since === "number");
});

test("message handler invokes onEvent(url, event) for matching kind:24133", () => {
  const factory = makeFactory();
  const received = [];
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    onEvent: (url, evt) => received.push({ url, evt }),
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  const event = { id: "e1", kind: 24133, pubkey: "c1", tags: [["p", "s1"]], content: "..." };
  factory.sockets[0].emit("message", Buffer.from(JSON.stringify(["EVENT", "clave-watch", event])));
  assert.equal(received.length, 1);
  assert.equal(received[0].url, "wss://a");
  assert.deepEqual(received[0].evt, event);
});

test("message handler ignores non-EVENT messages", () => {
  const factory = makeFactory();
  const received = [];
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    onEvent: (url, evt) => received.push({ url, evt }),
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  factory.sockets[0].emit("message", Buffer.from(JSON.stringify(["EOSE", "clave-watch"])));
  factory.sockets[0].emit("message", Buffer.from(JSON.stringify(["NOTICE", "hello"])));
  assert.equal(received.length, 0);
});

test("message handler ignores messages with wrong subscription id", () => {
  const factory = makeFactory();
  const received = [];
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    onEvent: (url, evt) => received.push({ url, evt }),
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  const event = { id: "e1", kind: 24133, pubkey: "c1", tags: [["p", "s1"]], content: "..." };
  factory.sockets[0].emit("message", Buffer.from(JSON.stringify(["EVENT", "other-sub", event])));
  assert.equal(received.length, 0);
});

test("refreshFilter sends CLOSE + new REQ on every open WS", () => {
  const factory = makeFactory();
  let signers = ["s1"];
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => signers,
  });
  pool.addRelay("wss://a");
  pool.addRelay("wss://b");
  factory.sockets[0]._openFromServer();
  factory.sockets[1]._openFromServer();
  // Clear the initial REQs from tracking
  factory.sockets[0].sent.length = 0;
  factory.sockets[1].sent.length = 0;

  signers = ["s1", "s2"];
  pool.refreshFilter();

  for (const ws of factory.sockets) {
    assert.equal(ws.sent.length, 2, "expect CLOSE then REQ on each WS");
    const [closeVerb, closeSubId] = JSON.parse(ws.sent[0]);
    assert.equal(closeVerb, "CLOSE");
    assert.equal(closeSubId, "clave-watch");
    const [reqVerb, reqSubId, filter] = JSON.parse(ws.sent[1]);
    assert.equal(reqVerb, "REQ");
    assert.equal(reqSubId, "clave-watch");
    assert.deepEqual(filter["#p"], ["s1", "s2"]);
  }
});

test("refreshFilter is a no-op for WSs not yet open", () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
  });
  pool.addRelay("wss://a");
  // Do NOT open the socket
  pool.refreshFilter();
  assert.equal(factory.sockets[0].sent.length, 0, "no messages sent to un-opened sockets");
});

test("on WS close, opens a new WS after backoff (still ref'd)", async () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    reconnectInitialMs: 10,
    reconnectMaxMs: 50,
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  // Simulate server-side disconnect
  factory.sockets[0].emit("close");
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(factory.sockets.length, 2, "should have created a replacement WS");
  assert.equal(factory.sockets[1]._url, "wss://a");
});

test("reconnect backoff grows on repeated failures, capped at max", async () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    reconnectInitialMs: 10,
    reconnectMaxMs: 40,
  });
  pool.addRelay("wss://a");
  // Three sequential failures — each close before open
  factory.sockets[0].emit("close"); // backoff 10ms → new WS
  await new Promise((r) => setTimeout(r, 20));
  factory.sockets[1].emit("close"); // backoff 20ms → new WS
  await new Promise((r) => setTimeout(r, 30));
  factory.sockets[2].emit("close"); // backoff 40ms (capped) → new WS
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(factory.sockets.length >= 4, `expected ≥ 4 sockets, got ${factory.sockets.length}`);
});

test("no reconnect after releaseRelay drops refcount to 0", async () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    reconnectInitialMs: 10,
    reconnectMaxMs: 50,
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  pool.releaseRelay("wss://a");
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(factory.sockets.length, 1, "should NOT create replacement after release");
});

test("heartbeat pings open socket on interval", async () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    pingIntervalMs: 20,
    pongTimeoutMs: 50,
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(factory.sockets[0].pingCount >= 2, `expected ≥2 pings, got ${factory.sockets[0].pingCount}`);
  pool.shutdown();
});

test("pong-timeout triggers ws.terminate()", async () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    pingIntervalMs: 10,
    pongTimeoutMs: 20,
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  // Do NOT emit 'pong' — simulate silent zombie socket
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(factory.sockets[0].terminated, "silent socket should have been terminated");
  pool.shutdown();
});

test("pong reply cancels pong-timeout", async () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    pingIntervalMs: 10,
    pongTimeoutMs: 30,
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  // Keep replying to every ping with a pong
  const pongInterval = setInterval(() => {
    factory.sockets[0].emit("pong");
  }, 5);
  await new Promise((r) => setTimeout(r, 50));
  clearInterval(pongInterval);
  assert.ok(!factory.sockets[0].terminated, "responsive socket should NOT be terminated");
  pool.shutdown();
});

test("heartbeat stops on release", async () => {
  const factory = makeFactory();
  const { createRelayPool } = require("../relayPool");
  const pool = createRelayPool({
    createSocket: factory,
    signerPubkeysProvider: () => ["s1"],
    pingIntervalMs: 10,
    pongTimeoutMs: 20,
  });
  pool.addRelay("wss://a");
  factory.sockets[0]._openFromServer();
  await new Promise((r) => setTimeout(r, 15));
  const pingCountBeforeRelease = factory.sockets[0].pingCount;
  pool.releaseRelay("wss://a");
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(factory.sockets[0].pingCount, pingCountBeforeRelease, "no further pings after release");
});
