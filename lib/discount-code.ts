/**
 * Decision 120: what the "Have a code?" box shows, read from
 * discount_code_preview / plan_buy_begin's preview. The sentences come from the
 * database (one place); this only shapes the answer.
 */
export type CodePreview = {
  ok: boolean;            // the code may be used here
  applied: boolean;       // and it beats the sale price, so it is what you pay
  code: string | null;
  listCents: number | null;
  priceCents: number | null;
  discountCents: number;
  currency: string | null;
  message: string | null; // a refusal, or why the sale price applies instead
};

export function previewFromPrice(p: Record<string, unknown> | null): CodePreview {
  const n = (v: unknown) => (v == null || v === "" ? null : Number(v));
  if (!p) return { ok: false, applied: false, code: null, listCents: null, priceCents: null, discountCents: 0, currency: null, message: "That code isn't valid." };
  const ok = p.code_ok === true;
  const applied = ok && p.code_applied === true;
  return {
    ok, applied,
    code: (p.code as string) ?? null,
    listCents: n(p.list_cents),
    priceCents: n(p.price_cents),
    discountCents: applied ? Number(p.discount_cents ?? 0) : 0,
    currency: (p.currency as string) ?? null,
    message: (p.code_message as string) ?? null,
  };
}

/** A PT460 is a code refusal whose message is the sentence to show. */
export function codeRefusal(err: { code?: string; message?: string } | null | undefined): string | null {
  if (!err) return null;
  if (err.code === "PT460" || /PT460/.test(err.message ?? "")) return (err.message ?? "").replace(/^.*?PT460:?\s*/, "") || "That code isn't valid.";
  return null;
}
