// Decision 103a: the reservation credit a member sees applied at checkout.
//
// Mirrors xendit_begin_purchase / xendit_begin_product_purchase exactly: the
// credit is applied up to the purchase total minus the processor floor (2000
// minor units), so the online payment is never below it. Any remainder stays on
// the account. This is the DISPLAY of what the begin function will apply.

/** The processor minimum left on every online payment (minor units). */
export const CREDIT_FLOOR_CENTS = 2000;

/**
 * How much reservation credit applies to a purchase of `priceCents`, and what
 * is left over. Pure; mirrors least(greatest(avail,0), greatest(price-floor,0)).
 * @param {number} creditCents available reservation credit (minor units)
 * @param {number} priceCents the gross purchase total (minor units)
 * @returns {{applied:number, remaining:number}}
 */
export function creditOnCheckout(creditCents, priceCents) {
  const credit = Math.max(0, Math.floor(creditCents || 0));
  const price = Math.max(0, Math.floor(priceCents || 0));
  const applied = Math.min(credit, Math.max(price - CREDIT_FLOOR_CENTS, 0));
  return { applied, remaining: credit - applied };
}

/**
 * The checkout lines, above the total. The "stays on your account" line only
 * shows when credit remains. `fmt` formats minor units to a currency string.
 * @param {number} applied
 * @param {number} remaining
 * @param {(cents:number)=>string} fmt
 * @returns {string[]} 0, 1 or 2 lines
 */
export function creditLines(applied, remaining, fmt) {
  const lines = [];
  if (applied > 0) lines.push(`${fmt(applied)} reservation credit applied.`);
  if (applied > 0 && remaining > 0) lines.push(`${fmt(remaining)} stays on your account.`);
  return lines;
}
