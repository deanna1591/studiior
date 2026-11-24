import { test } from "node:test";
import assert from "node:assert/strict";
import { classLineText, statusChip, settleWording, disputeMailto } from "../lib/pay-statement.mjs";

test("classLineText finalised shows checked in", () => {
  assert.equal(classLineText({ booked: 6, checkedIn: 4, finalised: true }), "6 booked · 4 checked in · paid on 4");
  // Decision 75(j): 6 booked, 4 attend, 2 no-show is paid on 6.
  assert.equal(classLineText({ booked: 6, checkedIn: 4, headsPaid: 6, finalised: true }), "6 booked · 4 checked in · paid on 6");
});
test("classLineText before finalisation awaits attendance", () => {
  assert.equal(classLineText({ booked: 6, checkedIn: null, finalised: false }), "6 booked · awaiting attendance");
  assert.equal(classLineText({ booked: 3, checkedIn: 2, finalised: false }), "3 booked · awaiting attendance");
});
test("statusChip maps the three states", () => {
  assert.equal(statusChip("open").label, "Open");
  assert.equal(statusChip("closed").label, "Closed");
  assert.equal(statusChip("paid").label, "Paid");
  assert.equal(statusChip("paid").tone, "paid");
});
test("settleWording: paid, expected, empty", () => {
  assert.equal(settleWording({ status: "paid", paidOn: "15 Feb", method: "bank_transfer" }), "Paid 15 Feb · bank transfer");
  assert.equal(settleWording({ status: "closed", settleOn: "28 Oct" }), "Payment expected 28 Oct");
  assert.equal(settleWording({ status: "open", settleOn: null }), "");
});
test("disputeMailto builds a prefilled mailto, null without an email", () => {
  const m = disputeMailto({ email: "d@x.com", periodLabel: "1–15 Oct", lineName: "Reformer", lineWhen: "Mon 06 Oct", amount: "CZK 900" });
  assert.ok(m.startsWith("mailto:d@x.com?subject="));
  assert.ok(m.includes(encodeURIComponent("Pay statement 1–15 Oct")));
  assert.ok(m.includes(encodeURIComponent("Reformer")));
  assert.equal(disputeMailto({ email: null }), null);
});

test("75 (l): full house and holding fee read on the line", async () => {
  const { classLineText } = await import("../lib/pay-statement.mjs");
  assert.equal(classLineText({ booked: 6, checkedIn: 6, headsPaid: 6, finalised: true, fullHouse: true }),
    "6 booked · 6 checked in · paid on 6 · full house");
  assert.equal(classLineText({ booked: 0, checkedIn: 0, headsPaid: 0, finalised: true, holdingFee: true }),
    "0 booked · 0 checked in · paid on 0 · nobody came, holding fee");
});

test("75 (l): did-not-run and cancel causes read in plain words", async () => {
  const { lineStatusWords } = await import("../lib/pay-statement.mjs");
  assert.equal(lineStatusWords("did not run"), "Did not run");
  assert.equal(lineStatusWords("cancelled — studio_fault"), "Cancelled by the studio");
  assert.equal(lineStatusWords("cancelled — force_majeure"), "Cancelled for a typhoon or suspension");
  assert.equal(lineStatusWords("cancelled — closure"), "Studio closed");
  assert.equal(lineStatusWords(null), "");
});
