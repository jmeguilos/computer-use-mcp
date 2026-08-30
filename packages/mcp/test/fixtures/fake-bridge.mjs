#!/usr/bin/env node

import readline from "node:readline";

let connectionId = "connection-123456";
let connectionToken = "connection-token-123456";
let hello = {};
let cancelCount = 0;

function response(id, result) {
  process.stdout.write(`${JSON.stringify({ protocol: { major: 1, minor: 0 }, id, ok: true, result })}\n`);
}

function failure(id, code, message, retryable, details) {
  process.stdout.write(
    `${JSON.stringify({
      protocol: { major: 1, minor: 0 },
      id,
      ok: false,
      error: { code, message, retryable, ...(details === undefined ? {} : { details }) }
    })}\n`
  );
}

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on("line", line => {
  const request = JSON.parse(line);
  if (request.method === "hello") {
    hello = request;
    process.stderr.write("fake bridge ready\n");
    response(request.id, {
      connectionId,
      connectionToken,
      acceptedCapabilities: request.capabilities,
      idleExpiresAt: "2099-01-01T00:00:00.000Z"
    });
    return;
  }
  if (request.connectionId !== connectionId || request.connectionToken !== connectionToken) {
    failure(request.id, "AUTH_FAILED", "bad connection", false);
    return;
  }
  if (request.method === "cancel") {
    cancelCount += 1;
    response(request.id, { cancelled: true });
    return;
  }
  if (request.method === "status") {
    if (process.env.FAKE_BRIDGE_HUGE === "1") {
      response(request.id, { data: "x".repeat(4096) });
      return;
    }
    response(request.id, {
      helloHadAuth: Object.hasOwn(hello, "auth"),
      helloHadPid: Object.hasOwn(hello.client ?? {}, "pid"),
      helloHadUid: Object.hasOwn(hello.client ?? {}, "uid"),
      cancelCount
    });
    return;
  }
  if (request.method === "action" && request.params?.kind === "delay") return;
  if (request.method === "action" && request.params?.kind === "stale") {
    failure(request.id, "stale_frame", "refresh state", true);
    return;
  }
  if (request.method === "action" && request.params?.kind === "risk") {
    failure(request.id, "approval_required", "Confirm risky action", false, {
      approvalRequestId: "approval-request-123456",
      riskTier: "high",
      expiresAt: "2099-01-01T00:00:00.000Z",
      approvalMode: "native"
    });
    return;
  }
  response(request.id, { echoedMethod: request.method, echoedParams: request.params });
});
