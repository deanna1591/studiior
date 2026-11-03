import { test } from "node:test";
import assert from "node:assert/strict";
import {
  walletBuckets, usedOfTotal, membershipTab, membershipChip, receiptMethod, onlineStatusLabel,
} from "../lib/wallet.mjs";

test("walletBuckets splits paid / refunded and passes online→unpaid, desk→desk", () => {
  const wallet = {
    payments: [
      { id: "a", status: "succeeded", refunded_cents: 0 },
      { id: "b", status: "succeeded", refunded_cents: 5000 },      // refunded wins
      { id: "c", status: "partially_refunded", refunded_cents: 200 }, // refund recorded
      { id: "d", status: "failed", refunded_cents: 0 },            // never shown
    ],
    online: [{ id: "x" }],
    desk: [{ booking_id: "k" }],
  };
  const b = walletBuckets(wallet);
  assert.deepEqual(b.paid.map((p) => p.id), ["a"]);
  assert.deepEqual(b.refunded.map((p) => p.id), ["b", "c"]);
  assert.deepEqual(b.unpaid.map((p) => p.id), ["x"]);
  assert.deepEqual(b.desk.map((p) => p.booking_id), ["k"]);
});

test("walletBuckets tolerates missing arrays", () => {
  const b = walletBuckets({});
  assert.deepEqual(b, { unpaid: [], paid: [], refunded: [], desk: [] });
});

test("usedOfTotal", () => {
  assert.equal(usedOfTotal({ plan_credits: 10, credits_remaining: 4 }), "6 of 10 classes used");
  assert.equal(usedOfTotal({ plan_credits: 10, credits_remaining: 10 }), "0 of 10 classes used");
  assert.equal(usedOfTotal({ plan_credits: null, credits_remaining: 3 }), null); // unlimited → no line
  assert.equal(usedOfTotal({ plan_credits: 5, credits_remaining: 8 }), "0 of 5 classes used"); // topped up, floor 0
});

test("membershipTab", () => {
  assert.equal(membershipTab("recurring"), "subscriptions");
  assert.equal(membershipTab("class_pack"), "passes");
  assert.equal(membershipTab("drop_in"), "passes");
  assert.equal(membershipTab("trial"), "passes");
});

test("membershipChip", () => {
  assert.equal(membershipChip("active"), "Active");
  assert.equal(membershipChip("trialing"), "Active");
  assert.equal(membershipChip("frozen"), "Active");
  assert.equal(membershipChip("past_due"), "Active");
  assert.equal(membershipChip("cancelled"), "Expired");
  assert.equal(membershipChip("expired"), "Expired");
});

test("receiptMethod", () => {
  assert.equal(receiptMethod("manual", "cash"), "Desk");
  assert.equal(receiptMethod("manual", "card_terminal"), "Desk");
  assert.equal(receiptMethod("stripe", null), "Card");
  assert.equal(receiptMethod("xendit", "gcash"), "GCash");
  assert.equal(receiptMethod("xendit", null), "Card");
});

test("onlineStatusLabel", () => {
  assert.equal(onlineStatusLabel("pending"), "Not finished");
  assert.equal(onlineStatusLabel("expired"), "Expired before it was paid");
  assert.equal(onlineStatusLabel("failed"), "Didn’t go through");
});
