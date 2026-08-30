"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getMemberContext } from "@/lib/auth";

export async function signIn(_prev: string | null, formData: FormData) {
  const supabase = createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: String(formData.get("email") ?? ""),
    password: String(formData.get("password") ?? ""),
  });
  if (error) return error.message;
  redirect("/");
}

export async function signOut() {
  const supabase = createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

/**
 * Every failure reason book_class() can return, in the member's words.
 *
 * The gate itself lives in SQL and is not duplicated here — this maps a code to
 * a sentence, nothing more. An unmapped code falls through to the raw code
 * rather than a generic "cannot book", because Business Rules §2.1 requires the
 * member to be told which rule stopped them.
 */
const REASONS: Record<string, string> = {
  not_found: "That class no longer exists.",
  member_not_found: "We could not find your membership record.",
  member_wrong_studio: "That class belongs to a different studio.",
  not_authorised: "You are not allowed to book that.",
  unsupported_payment_source: "That payment method cannot be chosen here.",
  class_cancelled: "That class has been cancelled.",
  class_completed: "That class has already finished.",
  class_in_past: "That class has already started.",
  outside_booking_window: "That class is not open for booking yet.",
  past_booking_cutoff: "Booking has closed for that class.",
  waiver_not_signed: "Please sign the studio waiver before booking.",
  member_not_active: "Your membership is not active.",
  already_booked: "You are already on the list for that class.",
  daily_limit_reached: "You have reached your class limit for that day.",
  future_limit_reached: "You have reached your limit of classes booked ahead.",
  class_type_not_in_plan: "Your plan does not cover that class type.",
  class_full: "That class is full and has no waitlist.",
  waitlist_closed: "The waitlist has closed for that class.",
};

export type BookResult = { ok: true; message: string } | { ok: false; message: string } | null;

export async function bookClass(_prev: BookResult, formData: FormData): Promise<BookResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const supabase = createClient();

  // The whole eligibility gate, payment source resolution, capacity check,
  // credit consumption and waitlist placement happen inside this one call,
  // in one transaction with the occurrence row locked. Nothing about that is
  // reimplemented on this side (CLAUDE.md).
  const { data, error } = await supabase.rpc("book_class", {
    p_occurrence_id: String(formData.get("occurrence_id") ?? ""),
    p_member_id: ctx.memberId,
    p_source: "member",
  });

  if (error) return { ok: false, message: error.message };

  const result = data as unknown as {
    booking_id: string | null;
    status: string | null;
    payment_source: string | null;
    waitlist_position: number | null;
    failure_reason: string | null;
  } | null;

  if (!result) return { ok: false, message: "No response from the booking function." };

  if (result.failure_reason) {
    return { ok: false, message: REASONS[result.failure_reason] ?? result.failure_reason };
  }

  revalidatePath("/");

  if (result.status === "waitlisted") {
    return { ok: true, message: `You are #${result.waitlist_position} on the waitlist. No credit taken.` };
  }

  const paid =
    result.payment_source === "membership" ? "covered by your membership"
    : result.payment_source === "class_pack" ? "one class pack credit used"
    : result.payment_source === "comp" ? "complimentary"
    : "drop-in, payable at the studio";

  return { ok: true, message: `Booked — ${paid}.` };
}
