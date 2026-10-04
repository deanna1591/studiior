"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/**
 * Decision 49 — the five actions a membership needs, one server action per RPC.
 *
 * Each returns the SQL's own sentence on success, or the database's message on a
 * refusal (the PT guards raise human sentences — "this plan cannot be paused",
 * "a reason is needed to extend" — so they are shown as-is). The real boundary
 * is the RPC, which is manager-up inside; these are thin wrappers that the
 * member screen and the Sales table both call.
 */
export type MembershipActionResult = { ok: true; sentence: string } | { error: string };

function revalidate() {
  revalidatePath("/members/[id]", "page");
  revalidatePath("/members");
  revalidatePath("/sales");
  revalidatePath("/due");
  revalidatePath("/");
}

function result(
  data: unknown,
  error: { message: string } | null,
): MembershipActionResult {
  if (error) return { error: error.message };
  const r = data as { ok?: boolean; sentence?: string } | null;
  if (!r?.ok) return { error: "That could not be done." };
  revalidate();
  return { ok: true, sentence: r.sentence ?? "Done." };
}

// Decision 61: grant a complimentary (free, ongoing) membership. The RPC
// returns {message} rather than {sentence}, so it maps its own result.
export async function grantComplimentary(
  memberId: string, planId: string, endsOn: string | null, reason: string,
): Promise<MembershipActionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("grant_complimentary_membership", {
    p_member_id: memberId,
    p_plan_id: planId,
    p_ends_on: endsOn || undefined,
    p_reason: reason.trim(),
  });
  if (error) return { error: error.message };
  const r = data as { message?: string } | null;
  if (!r?.message) return { error: "That could not be done." };
  revalidate();
  return { ok: true, sentence: r.message };
}

export async function endMembership(
  id: string, keepCredits: boolean, reason: string,
): Promise<MembershipActionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("end_membership", {
    p_membership_id: id,
    p_keep_credits: keepCredits,
    p_reason: reason.trim() || undefined,
  });
  return result(data, error);
}

export async function freezeMembership(
  id: string, until: string,
): Promise<MembershipActionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("freeze_membership", {
    p_membership_id: id,
    p_until: until,
  });
  return result(data, error);
}

export async function unfreezeMembership(id: string): Promise<MembershipActionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("unfreeze_membership", {
    p_membership_id: id,
  });
  return result(data, error);
}

export async function extendMembership(
  id: string, newExpiresOn: string, reason: string,
): Promise<MembershipActionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("extend_membership", {
    p_membership_id: id,
    p_new_expires_on: newExpiresOn,
    p_reason: reason,
  });
  return result(data, error);
}

export async function markMembershipPaid(
  id: string, amountCents: number, method: string,
): Promise<MembershipActionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("mark_membership_paid", {
    p_membership_id: id,
    p_amount_cents: amountCents,
    p_method: method,
  });
  return result(data, error);
}

export async function refundMembership(
  id: string, amountCents: number | null, reason: string, end: boolean,
): Promise<MembershipActionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("refund_membership", {
    p_membership_id: id,
    p_amount_cents: amountCents ?? undefined,
    p_reason: reason.trim() || undefined,
    p_end: end,
  });
  return result(data, error);
}
