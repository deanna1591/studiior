// Decision 88(c) — the invoice arithmetic/labels and the Payments-tab rows.
// node --test test/invoice.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { computeInvoice, vatOf, roundCents, invoiceMethod, pesoStr, hasInvoiceDetails } from "../lib/invoice.mjs";
import { paymentRows, PAYMENT_FILTERS } from "../lib/wallet.mjs";

test("roundCents — half away from zero (Python ROUND_HALF_UP)", () => {
  assert.equal(roundCents(112.5), 113);
  assert.equal(roundCents(112.4), 112);
  assert.equal(roundCents(113035.714), 113036);
  assert.equal(roundCents(0), 0);
  assert.equal(roundCents(-0.5), -1);
});

test("vatOf — VAT contained in a 12% VAT-inclusive gross (cents)", () => {
  assert.equal(vatOf(105000), 11250);     // ₱1,050 → ₱112.50 VAT
  assert.equal(vatOf(1055000), 113036);   // the two-item sample → ₱1,130.36
  assert.equal(vatOf(0), 0);
  assert.equal(vatOf(100000, 0), 0);      // non-VAT studio
});

test("computeInvoice — mirrors compute() for a normal sale", () => {
  // the rpc_invoice.py sample: ₱9,500 + ₱1,050
  const s = computeInvoice([{ qty: 1, price: 950000 }, { qty: 1, price: 105000 }]);
  assert.equal(s.totalSalesVatInclusive, 1055000);
  assert.equal(s.lessVat, 113036);
  assert.equal(s.amountNetOfVat, 941964);
  assert.equal(s.totalDue, 941964);
  assert.equal(s.amountDue, 941964);
  assert.equal(s.addVat, 113036);
  assert.equal(s.totalAmountDue, 1055000);
  assert.equal(s.vatableSales, 941964);
  assert.equal(s.vatExemptSales, 0);
  assert.equal(s.vatAmount, 113036);
});

test("computeInvoice — a refund row nets the sale down (full and partial)", () => {
  const full = computeInvoice([{ qty: 1, price: 280000 }, { qty: 1, price: -280000, desc: "Refund" }]);
  assert.equal(full.totalSalesVatInclusive, 0);
  assert.equal(full.lessVat, 0);
  assert.equal(full.totalAmountDue, 0);

  const partial = computeInvoice([{ qty: 1, price: 280000 }, { qty: 1, price: -100000, desc: "Refund" }]);
  assert.equal(partial.totalSalesVatInclusive, 180000);
  assert.equal(partial.lessVat, 19286);          // round(180000*12/112)
  assert.equal(partial.amountNetOfVat, 160714);
  assert.equal(partial.totalAmountDue, 180000);
});

test("computeInvoice — SC/PWD discount makes the sale VAT-exempt", () => {
  const s = computeInvoice([{ qty: 1, price: 105000 }], { scpwdDiscount: 21000 });
  assert.equal(s.lessScpwdDiscount, 21000);
  assert.equal(s.addVat, 0);                      // exempt → no VAT added
  assert.equal(s.vatableSales, 0);
  assert.equal(s.vatExemptSales, s.amountNetOfVat);
  assert.equal(s.totalAmountDue, s.amountNetOfVat - 21000);
});

test("invoiceMethod — the five BIR chips", () => {
  assert.equal(invoiceMethod("manual", "cash"), "Cash");
  assert.equal(invoiceMethod("manual", "gcash"), "GCash");
  assert.equal(invoiceMethod("manual", "maya"), "Maya");
  assert.equal(invoiceMethod("manual", "bank_transfer"), "Bank Transfer");
  assert.equal(invoiceMethod("manual", "card_terminal"), "Card");
  assert.equal(invoiceMethod("manual", null), "Cash");
  assert.equal(invoiceMethod("stripe", null), "Card");
  assert.equal(invoiceMethod("xendit", "gcash"), "GCash");
  assert.equal(invoiceMethod("xendit", "card"), "Card");
  assert.equal(invoiceMethod("xendit", null), "Card");
});

test("pesoStr — ₱ with thousands and two decimals", () => {
  assert.equal(pesoStr(1055000), "₱ 10,550.00");
  assert.equal(pesoStr(0), "₱ 0.00");
  assert.equal(pesoStr(11250), "₱ 112.50");
});

test("hasInvoiceDetails — needs a registered name AND a TIN", () => {
  assert.equal(hasInvoiceDetails({ invoice_registered_name: "RPC", invoice_tin: "123" }), true);
  assert.equal(hasInvoiceDetails({ invoice_registered_name: "RPC", invoice_tin: "" }), false);
  assert.equal(hasInvoiceDetails({ invoice_registered_name: "", invoice_tin: "123" }), false);
  assert.equal(hasInvoiceDetails(null), false);
});

test("paymentRows — one newest-first list with the right chip per kind", () => {
  const wallet = {
    payments: [
      { id: "p1", status: "succeeded", refunded_cents: 0, amount_cents: 180000, currency: "PHP", item: "10-Class Pack", at: "2026-11-05T10:00:00Z" },
      { id: "p2", status: "succeeded", refunded_cents: 180000, refunded_at: "2026-11-06T10:00:00Z", amount_cents: 180000, currency: "PHP", item: "Single Drop-in", at: "2026-11-01T10:00:00Z" },
    ],
    online: [
      { id: "x1", status: "expired", amount_cents: 150000, currency: "PHP", item: "Unlimited", at: "2026-11-04T10:00:00Z" },
    ],
    desk: [
      { booking_id: "b1", item: "Reformer Flow", starts_at: "2026-11-07T01:00:00Z", due_cents: 105000, currency: "PHP" },
    ],
  };
  const rows = paymentRows(wallet);
  const byKind = Object.fromEntries(rows.map((r) => [r.kind, r]));
  assert.equal(byKind.paid.chip, "Paid");
  assert.equal(byKind.paid.invoiceable, true);
  assert.equal(byKind.refunded.chip, "Refunded");
  assert.equal(byKind.refunded.invoiceable, true);
  assert.equal(byKind.refunded.refunded_cents, 180000);
  assert.equal(byKind.desk.chip, "Owed at the desk");
  assert.equal(byKind.desk.invoiceable, false);
  assert.equal(byKind.unpaid.chip, "Not completed");
  assert.equal(byKind.unpaid.invoiceable, false);
  // newest "at" first: desk (Nov 7) > refunded (refunded Nov 6) > paid (Nov 5) > unpaid (Nov 4)
  assert.deepEqual(rows.map((r) => r.kind), ["desk", "refunded", "paid", "unpaid"]);
  // only paid/refunded carry a payment id for the invoice link
  assert.equal(byKind.paid.paymentId, "p1");
  assert.equal(byKind.desk.paymentId, null);
});

test("PAYMENT_FILTERS — the four filter chips", () => {
  assert.deepEqual(PAYMENT_FILTERS.map((f) => f.key), ["paid", "refunded", "desk", "unpaid"]);
});
