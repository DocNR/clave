"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  isSessionFatalError,
  shouldPruneToken,
  parseReason,
  FATAL_SESSION_CODES,
  FATAL_NGHTTP2_CODES,
} = require("../apnsClient");

// ---------------------------------------------------------------------------
// isSessionFatalError
// ---------------------------------------------------------------------------

test("isSessionFatalError: nullish → false", () => {
  assert.equal(isSessionFatalError(null), false);
  assert.equal(isSessionFatalError(undefined), false);
});

test("isSessionFatalError: GOAWAY-related code triggers", () => {
  for (const code of FATAL_SESSION_CODES) {
    assert.equal(
      isSessionFatalError({ code, message: code }),
      true,
      `expected ${code} to be fatal`
    );
  }
});

test("isSessionFatalError: nghttp2 codes in message string trigger", () => {
  for (const code of FATAL_NGHTTP2_CODES) {
    assert.equal(
      isSessionFatalError({ message: `Stream closed with error code ${code}` }),
      true,
      `expected message containing ${code} to be fatal`
    );
  }
});

test("isSessionFatalError: GOAWAY substring in message triggers", () => {
  // The actual error from prod that started this whole investigation.
  const err = new Error(
    "New streams cannot be created after receiving a GOAWAY"
  );
  assert.equal(isSessionFatalError(err), true);
});

test("isSessionFatalError: benign per-request error → false", () => {
  assert.equal(
    isSessionFatalError({ code: "ERR_HTTP2_INVALID_STREAM", message: "x" }),
    false,
    "single-stream errors should NOT invalidate the whole session"
  );
  assert.equal(
    isSessionFatalError(new Error("request timeout")),
    false
  );
});

// ---------------------------------------------------------------------------
// shouldPruneToken
// ---------------------------------------------------------------------------

test("shouldPruneToken: 410 always prunes", () => {
  assert.equal(shouldPruneToken(410, ""), true);
  assert.equal(shouldPruneToken(410, '{"reason":"Unregistered"}'), true);
  assert.equal(shouldPruneToken(410, null), true);
});

test("shouldPruneToken: 400 BadDeviceToken prunes", () => {
  assert.equal(
    shouldPruneToken(400, '{"reason":"BadDeviceToken"}'),
    true,
    "the bug we're fixing — these previously survived forever"
  );
});

test("shouldPruneToken: 400 DeviceTokenNotForTopic prunes", () => {
  assert.equal(
    shouldPruneToken(400, '{"reason":"DeviceTokenNotForTopic"}'),
    true
  );
});

test("shouldPruneToken: 400 with other reasons does NOT prune", () => {
  // PayloadTooLarge means "this push was too big" — the token itself is
  // still valid; pruning would lose deliverability on the next push.
  assert.equal(
    shouldPruneToken(400, '{"reason":"PayloadTooLarge"}'),
    false
  );
  assert.equal(
    shouldPruneToken(400, '{"reason":"BadCertificate"}'),
    false
  );
  assert.equal(
    shouldPruneToken(400, ""),
    false,
    "no body — be conservative, don't prune"
  );
});

test("shouldPruneToken: 200 / 5xx never prune", () => {
  assert.equal(shouldPruneToken(200, "OK"), false);
  assert.equal(shouldPruneToken(429, '{"reason":"TooManyRequests"}'), false);
  assert.equal(shouldPruneToken(500, '{"reason":"InternalServerError"}'), false);
  assert.equal(shouldPruneToken(503, '{"reason":"ServiceUnavailable"}'), false);
});

test("shouldPruneToken: accepts pre-parsed body object", () => {
  assert.equal(
    shouldPruneToken(400, { reason: "BadDeviceToken" }),
    true,
    "callers may pass already-parsed JSON"
  );
});

// ---------------------------------------------------------------------------
// parseReason
// ---------------------------------------------------------------------------

test("parseReason: extracts JSON reason", () => {
  assert.equal(parseReason('{"reason":"BadDeviceToken"}'), "BadDeviceToken");
});

test("parseReason: returns null for empty/non-JSON", () => {
  assert.equal(parseReason(""), null);
  assert.equal(parseReason(null), null);
  assert.equal(parseReason(undefined), null);
  assert.equal(parseReason("not json"), null);
});

test("parseReason: passes through pre-parsed objects", () => {
  assert.equal(parseReason({ reason: "Unregistered" }), "Unregistered");
  assert.equal(parseReason({ other: "field" }), null);
});
