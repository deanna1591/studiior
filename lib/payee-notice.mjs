// Decision 67(b) — the Xendit payee notice shown on every screen that sends a
// member to Xendit (class checkout + pay sheet, Account → Plans, the shop
// purchase step). One sentence, nothing after it. Blank name → no line. A
// trailing period on the stored name is stripped so the sentence's own period
// never doubles up ("Corp.." → "Corp."). Pure, node-tested.
export function payeeNoticeLine(studioName, payeeNoticeName) {
  const payee = (payeeNoticeName ?? "").trim().replace(/\.+$/, "");
  if (!payee) return null;
  return `Note: Card and GCash payments for ${studioName} are processed by ${payee}.`;
}
