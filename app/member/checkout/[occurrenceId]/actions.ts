"use server";

import { getMemberContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { beginXenditCheckout, type BuyState } from "@/app/member/account/plan/actions";
import { REASONS } from "@/lib/booking-reasons";

/**
 * Decision 88 slice A — "Continue to pay".
 *
 * NO new money code and NO new hold logic: the seat is held exactly as today's
 * drop-in booking does — book_class creates the unpaid drop_in and locks the
 * seat — and payment is the shared beginXenditCheckout the plans page uses. On
 * activation the unchanged apply_plan_to_unpaid settles the held drop_in with a
 * credit from whatever plan was bought (Decision 73b/244).
 *
 * Two book_class outcomes are NON-fatal and still proceed to pay:
 *  - already_booked: the member already holds the unpaid drop_in (this is the
 *    old "Pay now" case, now routed here) — the seat is already held.
 *  - desk_pay_blocked (Decision 73c): a blocked member cannot hold an unpaid
 *    desk seat, so we skip the hold and buy the plan; on return they Book the
 *    class covered (they now hold a plan). The seat is not pre-held for them —
 *    the one place the no-new-code constraint and the blocked case do not fully
 *    reconcile, and it is deliberate.
 * A real refusal (full, past the cutoff, month not published) stops the payment.
 */
const HOLD_NON_FATAL = new Set(["already_booked", "desk_pay_blocked"]);

export async function checkoutPay(_prev: BuyState, fd: FormData): Promise<BuyState> {
  const occId = String(fd.get("occurrence_id") ?? "").trim();
  const planId = String(fd.get("plan_id") ?? "").trim();
  if (!occId || !planId) return { ok: false, message: "Something’s missing — try again." };

  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("book_class", {
    p_occurrence_id: occId, p_member_id: ctx.memberId, p_source: "member",
  });
  if (error) return { ok: false, message: error.message };
  const reason = (data as { failure_reason: string | null } | null)?.failure_reason ?? null;
  if (reason && !HOLD_NON_FATAL.has(reason)) {
    return { ok: false, message: REASONS[reason] ?? reason };
  }

  // Land back on the class after a successful purchase (the existing Pay-now
  // return behaviour), where apply_plan_to_unpaid will already have settled it.
  return beginXenditCheckout(ctx, planId, `/class/${occId}`);
}

export type DeskState = { error: string } | { ok: true } | null;

/**
 * Decision 88 slice A — "Pay at the desk". Only offered when the drop-in is
 * selected AND desk_pay_available is true (Decision 73c). It creates the unpaid
 * desk booking exactly as today (book_class → a booked drop_in, held, unpaid)
 * and returns { ok } so the client navigates to the class page — a server
 * redirect to a member path would render the staff app.
 */
export async function payAtDesk(_prev: DeskState, fd: FormData): Promise<DeskState> {
  const occId = String(fd.get("occurrence_id") ?? "").trim();
  if (!occId) return { error: "Something’s missing — try again." };

  const ctx = await getMemberContext();
  if (!ctx) return { error: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("book_class", {
    p_occurrence_id: occId, p_member_id: ctx.memberId, p_source: "member",
  });
  if (error) return { error: error.message };
  const reason = (data as { failure_reason: string | null } | null)?.failure_reason ?? null;
  if (reason && reason !== "already_booked") {
    return { error: REASONS[reason] ?? reason };
  }
  return { ok: true };
}
