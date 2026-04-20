const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

// Minimal in-process fake WebSocket — mimics the subset of `ws` API the pool uses.
function makeFakeSocket() {
  const ws = new EventEmitter();
  ws.readyState = 0; // CONNECTING
  ws.sent = [];
  ws.send = (msg) => ws.sent.push(msg);
  ws.ping = () => {};
  ws.close = () => {
    ws.readyState = 3; // CLOSED
    ws.emit("close");
  };
  ws.terminate = () => {
    ws.readyState = 3;
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
