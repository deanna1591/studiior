"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getMemberContext } from "@/lib/auth";
import { stripeFor } from "@/lib/stripe";
import { memberOrigin } from "@/lib/tenant";

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

  revalidateMember();

  if (result.status === "waitlisted") {
    return { ok: true, message: `You are #${result.waitlist_position} on the waitlist. No credit taken.` };
  }

  // A held seat is not a booking yet, and saying "Booked" would be a lie with
  // a fifteen-minute fuse on it — the sweep takes the seat back if the member
  // never finishes paying.
  if (result.status === "pending_payment") {
    return {
      ok: true,
      message: "We're holding your spot. Finish paying to confirm it.",
    };
  }

  const paid =
    result.payment_source === "membership" ? "covered by your membership"
    : result.payment_source === "class_pack" ? "one class pack credit used"
    : result.payment_source === "comp" ? "complimentary"
    : "drop-in, payable at the studio";

  return { ok: true, message: `Booked — ${paid}.` };
}


/** Every member screen shows some slice of the same booking state. */
function revalidateMember() {
  for (const p of ["/", "/book", "/history", "/account"]) revalidatePath(p);
}

export type ActionResult = { ok: boolean; message: string } | null;

/**
 * Cancel, per Business Rules §3.1.
 *
 * The rule — before the cutoff the credit comes back, after it the credit is
 * used, and either way the seat is released — lives in cancel_booking(). This
 * turns its answer into a sentence, and says plainly when a credit did not
 * come back rather than leaving the member to notice a number that did not
 * move.
 */
export async function cancelBooking(_prev: ActionResult, formData: FormData): Promise<ActionResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("cancel_booking", {
    p_booking_id: String(formData.get("booking_id") ?? ""),
  });

  if (error) {
    if (error.code === "PT409") return { ok: false, message: "That booking has already been cancelled." };
    if (error.code === "PT403") return { ok: false, message: "That is not your booking." };
    return { ok: false, message: error.message };
  }

  const r = data as unknown as {
    status: string; credit_returned: boolean; reason: string | null; offer_made: boolean;
  } | null;
  if (!r) return { ok: false, message: "No response from the cancel function." };

  revalidateMember();

  const late = r.status === "late_cancelled";
  const head = late ? "Cancelled, inside the notice period." : "Cancelled.";
  const credit = r.credit_returned
    ? " Your credit is back on your account."
    : r.reason ? ` ${r.reason}`
    : "";
  return { ok: true, message: head + credit };
}

/**
 * Accept or decline a waitlist offer.
 *
 * Accepting re-runs the whole eligibility gate through book_class(), because
 * a membership can lapse between joining a waitlist and a seat opening — §4.2
 * says so, and this does not shortcut it.
 */
export async function respondToOffer(_prev: ActionResult, formData: FormData): Promise<ActionResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const accept = String(formData.get("accept") ?? "") === "1";
  const supabase = createClient();
  const { data, error } = await supabase.rpc("respond_to_offer", {
    p_offer_id: String(formData.get("offer_id") ?? ""),
    p_accept: accept,
  });

  if (error) {
    if (error.code === "PT409") return { ok: false, message: "That offer has already been answered." };
    return { ok: false, message: error.message };
  }

  const r = (data ?? {}) as { ok?: boolean; accepted?: boolean; reason?: string };
  revalidateMember();

  if (r.ok === false) {
    return r.reason === "expired"
      ? { ok: false, message: "That offer ran out before you got to it. You are off the list for this one." }
      : { ok: false, message: REASONS[r.reason ?? ""] ?? "That seat could not be taken." };
  }
  return r.accepted
    ? { ok: true, message: "You are in. See you there." }
    : { ok: true, message: "No problem — the seat goes to the next person." };
}

export type ClaimState = { error: string } | null;

/**
 * Take up an invite: account, profile and members.user_id, or none of it.
 *
 * The password never reaches this file's logic — claim_member_account() hashes
 * it in the same transaction that links the member, so there is no window in
 * which an account exists without the membership it was made for.
 */
export async function claimAccount(_prev: ClaimState, fd: FormData): Promise<ClaimState> {
  const token = String(fd.get("token") ?? "");
  const password = String(fd.get("password") ?? "");
  const fullName = String(fd.get("full_name") ?? "");

  if (password.length < 8) return { error: "Pick a password of at least 8 characters." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("claim_member_account", {
    p_token: token, p_password: password, p_full_name: fullName || undefined,
  });
  if (error) return { error: error.message };

  const r = data as unknown as { email: string | null; failure_reason: string | null } | null;
  if (!r) return { error: "No response from the server." };

  if (r.failure_reason) {
    const said: Record<string, string> = {
      invalid_token: "That link is not one of ours. Ask the studio for a new one.",
      token_used: "That link has already been used. If it wasn't you, ask the studio for a new one.",
      token_expired: "That link has expired. Ask the studio for a new one.",
      already_claimed: "There is already an account for this membership. Try signing in.",
      password_too_short: "Pick a password of at least 8 characters.",
    };
    return { error: said[r.failure_reason] ?? r.failure_reason };
  }

  // Sign them straight in — they have just proved they hold the invite.
  if (r.email) {
    await supabase.auth.signInWithPassword({ email: r.email, password });
  }
  redirect("/");
}

/**
 * After a self-signup, once the address is verified, attach the account to a
 * member record — or make one.
 *
 * The verification check is in claim_member_by_email(), not here. members is
 * unique on (studio_id, email), so an address names a person: linking before
 * the address is proven would hand their attendance and payments to anybody
 * who knew it. A check in this file would be a promise; a check in the
 * function is the rule.
 */
export async function finishSignup(_prev: ClaimState, fd: FormData): Promise<ClaimState> {
  const studioId = String(fd.get("studio_id") ?? "");
  const supabase = createClient();

  const { data, error } = await supabase.rpc("claim_member_by_email", { p_studio_id: studioId });
  if (error) return { error: error.message };

  const r = data as unknown as { failure_reason: string | null } | null;
  if (r?.failure_reason) {
    const said: Record<string, string> = {
      email_not_verified: "Confirm your email first — we've sent you a link. Then come back and press this again.",
      already_claimed: "Someone has already set up an account for that email at this studio. Ask the studio if that wasn't you.",
      not_signed_in: "Sign in first.",
      no_such_studio: "That studio is not taking signups.",
    };
    return { error: said[r.failure_reason] ?? r.failure_reason };
  }

  revalidateMember();
  redirect("/");
}

/** Self-signup: create the account, Supabase sends the confirmation. */
export async function signUp(_prev: ClaimState, fd: FormData): Promise<ClaimState> {
  const email = String(fd.get("email") ?? "").trim().toLowerCase();
  const password = String(fd.get("password") ?? "");
  const fullName = String(fd.get("full_name") ?? "").trim();

  if (!email) return { error: "We need an email address." };
  if (password.length < 8) return { error: "Pick a password of at least 8 characters." };

  const supabase = createClient();
  const { error } = await supabase.auth.signUp({
    email, password, options: { data: { full_name: fullName } },
  });
  if (error) {
    return /already registered/i.test(error.message)
      ? { error: "There is already an account for that email. Try signing in instead." }
      : { error: error.message };
  }
  redirect("/signup?sent=1");
}

/**
 * Email preferences.
 *
 * Five switches, one per opt-outable template. The three §12 events that always
 * send — a cancelled class, a substituted instructor, a failed payment — are not
 * here, because there is no switch for them and rendering one that silently did
 * nothing would be a lie told in a form control.
 *
 * Upsert rather than update: a member who has never opened this screen has no
 * row at all, and notification_wanted() reads a missing row as "everything on".
 * The first save is therefore an insert, and every later one an update.
 */
export async function updateEmailPreferences(
  _prev: string | null, formData: FormData,
): Promise<string | null> {
  const ctx = await getMemberContext();
  if (!ctx) return "Not signed in.";

  const supabase = createClient();
  const row = {
    member_id: ctx.memberId,
    studio_id: ctx.studioId,
    updated_at: new Date().toISOString(),
    booking_email: formData.get("booking_email") === "on",
    reminder_email: formData.get("reminder_email") === "on",
    waitlist_email: formData.get("waitlist_email") === "on",
    credit_expiry_email: formData.get("credit_expiry_email") === "on",
    milestone_email: formData.get("milestone_email") === "on",
  };

  // RLS refuses an UPDATE by making the row invisible, which PostgREST returns
  // as 200 and an empty array. Selecting back is how we know it saved.
  const { data, error } = await supabase
    .from("notification_preferences")
    .upsert(row, { onConflict: "member_id" })
    .select("member_id");

  if (error) return error.message;
  if (!data || data.length === 0) return "That did not save. Please try again.";

  revalidatePath("/settings");
  return "ok";
}

/**
 * The member's own profile.
 *
 * Writes straight to `members` under members_self_update, which is now bounded
 * by the trigger from migration 035: a member may change these fields and
 * nothing else. Before that trigger this same policy let a member sign their
 * own waiver and promote themselves to active, so the screen this action backs
 * would have been a form over a hole.
 */
export async function updateProfile(
  _prev: ActionResult, formData: FormData,
): Promise<ActionResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const supabase = createClient();
  const str = (k: string) => {
    const v = String(formData.get(k) ?? "").trim();
    return v === "" ? null : v;
  };

  const ecName = str("emergency_name");
  const ecPhone = str("emergency_phone");

  const { data, error } = await supabase
    .from("members")
    .update({
      preferred_name: str("preferred_name"),
      phone: str("phone"),
      // Stored as one object so it is either a usable contact or absent — a
      // name with no number is not somebody you can ring.
      emergency_contact: ecName || ecPhone ? { name: ecName, phone: ecPhone } : null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", ctx.memberId)
    .select("id");

  if (error) {
    return error.code === "PT403" || /may change their own contact details/.test(error.message)
      ? { ok: false, message: "That is not something you can change here — ask the studio." }
      : { ok: false, message: error.message };
  }
  // RLS refuses an UPDATE by making the row invisible, which PostgREST returns
  // as 200 and an empty array rather than an error.
  if (!data || data.length === 0) return { ok: false, message: "That did not save. Please try again." };

  revalidatePath("/account");
  revalidatePath("/");
  return { ok: true, message: "Saved." };
}

/**
 * Their photograph.
 *
 * Into `member-avatars`, which is private, under a path whose first segment is
 * the member's own id — the storage policy joins that back to `members` and
 * checks the caller owns the row, so a member uploads their photograph and
 * nobody else's whatever this function does. `members.avatar_url` holds the
 * object PATH, not a URL: every read is signed at render.
 */
export async function uploadAvatar(
  _prev: ActionResult, formData: FormData,
): Promise<ActionResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const file = formData.get("avatar") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  if (file.size > 2_000_000) {
    return { ok: false, message: "That photo is over 2 MB. Most phones can export a smaller one." };
  }
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    return { ok: false, message: "JPEG, PNG or WebP." };
  }

  const supabase = createClient();
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "jpg";
  const path = `${ctx.memberId}/avatar-${Date.now()}.${ext}`;

  const { error } = await supabase.storage
    .from("member-avatars")
    .upload(path, file, { cacheControl: "3600", upsert: false });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? { ok: false, message: "That photo could not be saved to your account." }
      : { ok: false, message: error.message };
  }

  const { data, error: upErr } = await supabase
    .from("members").update({ avatar_url: path }).eq("id", ctx.memberId).select("id");
  if (upErr) return { ok: false, message: upErr.message };
  if (!data || data.length === 0) {
    return { ok: false, message: "The photo uploaded but your profile could not be updated." };
  }

  revalidatePath("/account");
  revalidatePath("/");
  return { ok: true, message: "Photo updated." };
}

/**
 * Send a member to Stripe Checkout, hosted, on the STUDIO's account.
 *
 * Direct charges with no application fee: the money lands in the studio's own
 * balance and Studiior never holds it. Card details never touch this server —
 * the member leaves for Stripe and comes back.
 *
 * Everything the webhook will need travels in metadata, including price_cents,
 * which is the price the member is agreeing to right now. §7.1 is that editing
 * a plan never reprices anyone already on it, so the snapshot has to be taken
 * here, at the moment of agreement, and not re-read from the plan later.
 */
export async function startCheckout(
  _prev: ActionResult, formData: FormData,
): Promise<ActionResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const kind = String(formData.get("kind") ?? "");
  const planId = String(formData.get("plan_id") ?? "");
  const bookingId = String(formData.get("booking_id") ?? "");

  const supabase = createClient();
  const { data: studio } = await supabase
    .from("studios").select("id, name, slug, currency, stripe_account_id")
    .eq("id", ctx.studioId).maybeSingle();

  if (!studio?.stripe_account_id) {
    return { ok: false, message: "This studio is not taking card payments yet." };
  }

  const { data: member } = await supabase
    .from("members").select("email, first_name").eq("id", ctx.memberId).maybeSingle();

  const origin = memberOrigin(studio.slug);
  let url: string | null = null;

  try {
    const s = stripeFor(studio.stripe_account_id);

    if (kind === "dropin") {
      // The seat is already held as pending_payment; this is only the money.
      const { data: booking } = await supabase
        .from("bookings")
        .select("id, status, class_occurrences(name)")
        .eq("id", bookingId).eq("member_id", ctx.memberId).maybeSingle();
      if (!booking || booking.status !== "pending_payment") {
        return { ok: false, message: "That hold has expired. Book the class again." };
      }

      const { data: price } = await supabase
        .from("membership_plans").select("price_cents, currency")
        .eq("studio_id", studio.id).eq("type", "drop_in").eq("status", "active")
        .order("sort_order").limit(1).maybeSingle();
      if (!price) {
        return { ok: false, message: "This studio has not set a drop-in price yet." };
      }

      const session = await s.checkout.sessions.create({
        mode: "payment",
        customer_email: member?.email ?? undefined,
        line_items: [{
          quantity: 1,
          price_data: {
            currency: (price.currency ?? studio.currency ?? "usd").toLowerCase(),
            unit_amount: price.price_cents,
            product_data: { name: booking.class_occurrences?.name ?? "Drop-in class" },
          },
        }],
        success_url: `${origin}/?paid=1`,
        cancel_url: `${origin}/book?cancelled=1`,
        metadata: {
          kind: "dropin",
          studio_id: studio.id,
          member_id: ctx.memberId,
          booking_id: bookingId,
          price_cents: String(price.price_cents),
        },
      });
      url = session.url;
    } else {
      const { data: plan } = await supabase
        .from("membership_plans")
        .select("id, name, type, price_cents, currency, billing_interval, billing_interval_count")
        .eq("id", planId).eq("studio_id", studio.id).eq("status", "active").maybeSingle();
      if (!plan) return { ok: false, message: "That plan is no longer on sale." };

      const recurring = plan.type === "recurring";
      const session = await s.checkout.sessions.create({
        mode: recurring ? "subscription" : "payment",
        customer_email: member?.email ?? undefined,
        line_items: [{
          quantity: 1,
          price_data: {
            currency: (plan.currency ?? studio.currency ?? "usd").toLowerCase(),
            unit_amount: plan.price_cents,
            product_data: { name: plan.name },
            ...(recurring
              ? { recurring: {
                    interval: (plan.billing_interval ?? "month") as "day" | "week" | "month" | "year",
                    interval_count: plan.billing_interval_count ?? 1,
                  } }
              : {}),
          },
        }],
        success_url: `${origin}/account?paid=1`,
        cancel_url: `${origin}/account?cancelled=1`,
        metadata: {
          kind: "plan",
          studio_id: studio.id,
          member_id: ctx.memberId,
          plan_id: plan.id,
          // The snapshot. Taken now, never re-read from the plan later.
          price_cents: String(plan.price_cents),
        },
      });
      url = session.url;
    }
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : "Stripe refused that." };
  }

  if (!url) return { ok: false, message: "Stripe did not return a checkout link." };
  redirect(url);
}
