// Decision 88 (c) — the BIR service-invoice arithmetic and labels, pure and
// node-tested. Mirrors compute() in docs/invoice-reference/rpc_invoice.py
// (VAT-inclusive 12%, SC/PWD discount and withholding), but in integer cents so
// it cannot drift from the money the app stores. Items carry cents prices; a
// refund is an item line with a negative price (a refunded sale nets down).

/** Round fractional cents half away from zero (Python's ROUND_HALF_UP). */
export function roundCents(x) {
  const EPS = 1e-9;
  return x >= 0 ? Math.floor(x + 0.5 + EPS) : -Math.floor(-x + 0.5 + EPS);
}

/** VAT contained in a VAT-inclusive gross (in cents), at the given rate %. */
export function vatOf(grossCents, rate = 12) {
  if (!rate) return 0;
  return roundCents((grossCents * rate) / (100 + rate));
}

/**
 * The BIR tax summary for a set of items (cents), mirroring compute():
 * VAT-inclusive, with an optional SC/PWD discount and withholding tax (cents).
 * Every value is integer cents. When a discount applies the sale is VAT-exempt
 * (SC/PWD), exactly as the script treats it.
 * @param {{qty:number, price:number}[]} items  price in cents (negative = refund line)
 * @param {{scpwdDiscount?:number, withholding?:number, vatRate?:number}} [opts]
 */
export function computeInvoice(items, opts = {}) {
  const rate = opts.vatRate ?? 12;
  const disc = Math.round(opts.scpwdDiscount ?? 0);
  const wht = Math.round(opts.withholding ?? 0);
  const gross = (items ?? []).reduce((s, i) => s + Math.round(i.qty * i.price), 0);
  const vat = vatOf(gross, rate);
  const net = gross - vat;
  const totalDue = net - disc;
  const amountDue = totalDue - wht;
  const addVat = disc === 0 ? vat : 0; // SC/PWD sales are VAT-exempt
  const total = amountDue + addVat;
  return {
    totalSalesVatInclusive: gross,
    lessVat: vat,
    amountNetOfVat: net,
    lessScpwdDiscount: disc,
    totalDue,
    lessWithholding: wht,
    amountDue,
    addVat,
    totalAmountDue: total,
    vatableSales: disc === 0 ? net : 0,
    vatExemptSales: disc === 0 ? 0 : net,
    vatZeroRatedSales: 0,
    vatAmount: addVat,
  };
}

/**
 * The payment method named on the invoice, one of the five BIR chips the
 * template draws: Cash / GCash / Maya / Card / Bank Transfer. A desk payment
 * carries its method; Stripe is a card; Xendit presents card and GCash on its
 * hosted page, so a stored gcash method shows GCash and anything else Card.
 */
export function invoiceMethod(provider, method) {
  const m = (method ?? "").toLowerCase();
  if (provider === "manual") {
    if (m === "gcash") return "GCash";
    if (m === "maya") return "Maya";
    if (m === "bank_transfer") return "Bank Transfer";
    if (m === "card_terminal" || m === "card") return "Card";
    return "Cash"; // cash, or an unlabelled desk payment
  }
  if (provider === "stripe") return "Card";
  if (provider === "xendit") return m === "gcash" ? "GCash" : "Card";
  return m === "gcash" ? "GCash" : m === "maya" ? "Maya" : "Cash";
}

/** "₱ 1,234.56" from integer cents (the script's peso() format). */
export function pesoStr(cents) {
  const v = (cents ?? 0) / 100;
  return "₱ " + v.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** True when a studio has filled enough invoice detail to issue a BIR invoice. */
export function hasInvoiceDetails(s) {
  return !!(s && String(s.invoice_registered_name ?? "").trim() && String(s.invoice_tin ?? "").trim());
}
