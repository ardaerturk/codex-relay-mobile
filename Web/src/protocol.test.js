import test from "node:test";
import assert from "node:assert/strict";
import { reconcile } from "./protocol.js";
test("stream patches update, order, and remove messages without losing metadata", () => {
  const current = {
    id: "task",
    title: "Title",
    messages: [
      { id: "1", text: "a" },
      { id: "2", text: "b" },
    ],
  };
  const next = reconcile(current, {
    type: "conversationPatch",
    patch: {
      metadata: { id: "task", revision: 2 },
      upserts: [
        { id: "1", text: "updated" },
        { id: "3", text: "c" },
      ],
      order: ["3", "1"],
    },
  });
  assert.equal(next.title, "Title");
  assert.deepEqual(
    next.messages.map((x) => x.text),
    ["c", "updated"],
  );
  assert.equal(current.messages[0].text, "a");
});
test("missing or mismatched stream state requires a fresh snapshot", () => {
  const p = {
    type: "conversationPatch",
    patch: { metadata: { id: "task" }, upserts: [], order: ["missing"] },
  };
  assert.throws(() => reconcile(null, p));
  assert.throws(() => reconcile({ id: "other", messages: [] }, p));
  assert.throws(() => reconcile({ id: "task", messages: [] }, p));
});
test("unreadable successful response is a transport failure, not an authenticated session", async () => {
  const { api } = await import("./protocol.js");
  const original = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => {
      throw new Error("HTML response");
    },
  });
  try {
    await assert.rejects(api("/v1/health"), (e) => e.status === 502);
  } finally {
    globalThis.fetch = original;
  }
});
