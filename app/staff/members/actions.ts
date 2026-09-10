"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type MemberState = { error: string } | null;
export type InviteState = { ok: boolean; message: string } | null;

const text = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const nullable = (fd: FormData, k: string) => text(fd, k) || null;

const say = (m: string) =>
  /PT403/.test(m) ? "Your role cannot do that. Owners, managers and front desk only."
  : /PT404/.test(m) ? "That member no longer exists."
  : /PT409/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

/**
 * A walk-in signing up at the desk.
 *
 * Permissions §5 gives create to Owner, Manager AND Front Desk, and
 * `members_desk_write` implements it — the person at the counter is exactly who
 * does this, so the screen is not manager-gated.
 */
export async function createMember(_prev: MemberState, fd: FormData): Promise<MemberState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };

  const first_name = text(fd, "first_name");
  const last_name = text(fd, "last_name");
  const email = text(fd, "email").toLowerCase();
  if (!first_name || !last_name) return { error: "A member needs a first and last name." };
  if (!email) return { error: "An email address — it is how they get their account and their receipts." };
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { error: "That email does not look right." };

  // Both jsonb, and both written as null rather than {} when empty: an empty
  // object reads as "we asked and they had none", which is a different fact.
  const ec_name = text(fd, "ec_name");
  const ec_phone = text(fd, "ec_phone");
  const emergency_contact = ec_name || ec_phone
    ? { name: ec_name || null, phone: ec_phone || null, relationship: nullable(fd, "ec_relationship") }
    : null;
  const line1 = text(fd, "line1");
  const address = line1
    ? { line1, city: nullable(fd, "city"), postal_code: nullable(fd, "postal_code") }
    : null;

  const supabase = createClient();
  const { data, error } = await supabase.from("members").insert({
    studio_id: ctx.studioId,
    first_name, last_name, email,
    preferred_name: nullable(fd, "preferred_name"),
    phone: nullable(fd, "phone"),
    date_of_birth: nullable(fd, "date_of_birth"),
    emergency_contact,
    address,
    // Consent is a positive act. An unchecked box is a no, and defaulting it
    // true would opt a walk-in into marketing they never agreed to.
    marketing_opt_in: fd.get("marketing_opt_in") === "on",
    source: "front_desk",
    status: "active",
  }).select("id").maybeSingle();

  if (error) {
    if (/duplicate key|unique/i.test(error.message)) {
      return { error: "Somebody with that email is already a member here." };
    }
    return /row-level security/i.test(error.message) || error.code === "42501"
      ? { error: "Your role cannot add members." }
      : { error: error.message };
  }
  if (!data) return { error: "Nothing was saved. Your role may not add members." };

  revalidatePath("/members");
  redirect(`/members/${data.id}?added=1`);
}

/** One invite, from the member's own screen. */
export async function inviteMember(_prev: InviteState, fd: FormData): Promise<InviteState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("invite_member", {
    p_member_id: String(fd.get("member_id") ?? ""),
  });
  if (error) return { ok: false, message: say(error.message) };
  const r = data as unknown as
    { ok: boolean; reason?: string; hint?: string; member?: string; email?: string };

  if (!r.ok) {
    // Said on the screen rather than failing quietly somewhere downstream.
    return {
      ok: false,
      message: r.reason === "no_email"
        ? `${r.member} has no email address, so there is nowhere to send an invite. ${r.hint}`
        : `${r.member} already has an account — there is nothing to send.`,
    };
  }
  revalidatePath("/members");
  revalidatePath("/members/invites");
  return { ok: true, message: `Invite sent to ${r.email}. The link works for 14 days.` };
}

/** Everyone without an account — the case after an import. */
export async function inviteEveryone(_prev: InviteState, fd: FormData): Promise<InviteState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("invite_members_bulk", {
    p_studio_id: ctx.studioId,
  });
  if (error) return { ok: false, message: say(error.message) };
  const r = data as unknown as {
    invited: number; skipped_no_email: { member: string }[]; skipped_already_claimed: number;
  };
  revalidatePath("/members/invites");
  revalidatePath("/members");

  const bits = [`${r.invited} ${r.invited === 1 ? "invite" : "invites"} sent`];
  if (r.skipped_no_email.length) {
    bits.push(
      `${r.skipped_no_email.length} skipped with no email address: ` +
      r.skipped_no_email.map((x) => x.member).join(", "));
  }
  return { ok: r.invited > 0 || r.skipped_no_email.length === 0, message: `${bits.join(". ")}.` };
}
