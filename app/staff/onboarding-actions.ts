"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type ActionState = { error: string } | null;

/** Reasons the two invite functions can return, in the invitee's words. */
const INVITE_REASONS: Record<string, string> = {
  invalid_token: "That invite link is not valid. Check you copied the whole link, or ask for a new one.",
  token_already_used: "That invite has already been used. If this was you, sign in instead.",
  token_expired: "That invite has expired. Ask for a new link.",
  studio_already_has_owner: "This studio already has an owner, so the invite can no longer be used.",
  account_exists: "There is already an account for this email address. Sign in instead.",
  password_too_short: "Choose a password of at least 8 characters.",
  name_required: "Please give your name.",
};

// --- Platform admin -------------------------------------------------------

const PROVISION_REASONS: Record<string, string> = {
  not_platform_admin: "Your account cannot provision studios.",
  invalid_slug: "The slug must be lowercase letters, numbers and hyphens, 3–40 characters.",
  invalid_email: "That does not look like an email address.",
  slug_taken: "That slug is already in use by another studio.",
};

export async function provisionStudio(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const supabase = createClient();

  // No allowlist check here. provision_studio() asks platform_admins, and that
  // is the permission — a check in this file would only decide what to render.
  const { data, error } = await supabase.rpc("provision_studio", {
    p_name: String(fd.get("name") ?? "").trim(),
    p_slug: String(fd.get("slug") ?? "").trim(),
    p_timezone: String(fd.get("timezone") ?? "").trim(),
    p_currency: String(fd.get("currency") ?? "").trim().toUpperCase(),
    p_country: String(fd.get("country") ?? "").trim().toUpperCase(),
    p_owner_email: String(fd.get("owner_email") ?? "").trim(),
  });

  if (error) return { error: error.message };

  const r = data as unknown as {
    studio_id: string | null; invite_token: string | null;
    expires_at: string | null; failure_reason: string | null;
  } | null;

  if (!r) return { error: "No response from the database." };
  if (r.failure_reason) {
    return { error: PROVISION_REASONS[r.failure_reason] ?? r.failure_reason };
  }

  revalidatePath("/admin");
  // The token exists in plaintext exactly once, here. It is passed on in the
  // URL so the operator can copy the link, and never stored again.
  redirect(`/admin?token=${r.invite_token}&studio=${r.studio_id}`);
}

// --- Invite acceptance ----------------------------------------------------

export async function acceptInvite(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const token = String(fd.get("token") ?? "");
  const password = String(fd.get("password") ?? "");
  const supabase = createClient();

  const { data, error } = await supabase.rpc("accept_studio_invite", {
    p_token: token,
    p_password: password,
    p_full_name: String(fd.get("full_name") ?? "").trim(),
  });

  if (error) return { error: error.message };

  const r = data as unknown as {
    user_id: string | null; studio_id: string | null;
    studio_slug: string | null; email: string | null; failure_reason: string | null;
  } | null;

  if (!r) return { error: "No response from the database." };
  if (r.failure_reason) {
    return { error: INVITE_REASONS[r.failure_reason] ?? r.failure_reason };
  }

  // The account now exists; sign in with the credentials just set so the
  // wizard has a session to run in.
  const { error: signInError } = await supabase.auth.signInWithPassword({
    email: r.email!,
    password,
  });
  if (signInError) {
    return { error: `Your account was created, but sign-in failed: ${signInError.message}` };
  }

  redirect("/welcome");
}

// --- Wizard ---------------------------------------------------------------

export async function saveStudioIdentity(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const slug = String(fd.get("slug") ?? "").trim().toLowerCase();
  if (!/^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$/.test(slug)) {
    return { error: "The slug must be lowercase letters, numbers and hyphens, 3–40 characters." };
  }

  const supabase = createClient();
  const { data, error } = await supabase
    .from("studios")
    .update({
      name: String(fd.get("name") ?? "").trim(),
      slug,
      timezone: String(fd.get("timezone") ?? "").trim(),
      currency: String(fd.get("currency") ?? "").trim().toUpperCase(),
      country: String(fd.get("country") ?? "").trim().toUpperCase() || null,
    })
    .eq("id", ctx.studioId)
    .select("id");

  if (error) {
    return error.code === "23505"
      ? { error: "That slug is already taken by another studio." }
      : { error: error.message };
  }
  // studios_owner_write is UPDATE for owners only; a refused update returns
  // zero rows rather than an error.
  if (!data || data.length === 0) {
    return { error: "Only the owner can change the studio's identity." };
  }

  redirect("/welcome?step=3");
}

export async function saveBookingBasics(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const int = (k: string, fallback: number) => {
    const n = Number(String(fd.get(k) ?? "").trim());
    return Number.isFinite(n) && n >= 0 ? Math.floor(n) : fallback;
  };

  const supabase = createClient();
  const { data, error } = await supabase
    .from("studio_settings")
    .update({
      booking_window_days: int("booking_window_days", 30),
      cancellation_cutoff_minutes: int("cancellation_cutoff_minutes", 720),
      require_waiver: fd.get("require_waiver") === "on",
      // This is what stops the wizard blocking every other screen.
      onboarding_completed_at: new Date().toISOString(),
    })
    .eq("studio_id", ctx.studioId)
    .select("studio_id");

  if (error) return { error: error.message };
  if (!data || data.length === 0) {
    return { error: "Only owners and managers can change booking settings." };
  }

  revalidatePath("/", "layout");
  redirect("/");
}

// --- Dashboard checklist --------------------------------------------------

export async function dismissSetupItem(_prev: ActionState, fd: FormData): Promise<ActionState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();
  const { error } = await supabase.rpc("dismiss_setup_item", {
    p_studio_id: ctx.studioId,
    p_key: String(fd.get("key") ?? ""),
    p_dismissed: fd.get("undo") !== "1",
  });
  if (error) return { error: error.message };
  revalidatePath("/");
  return null;
}

export async function markStripeStubDone(_prev: ActionState, _fd: FormData): Promise<ActionState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();
  const { error } = await supabase.rpc("mark_stripe_stub_done", { p_studio_id: ctx.studioId });
  if (error) return { error: error.message };
  revalidatePath("/");
  redirect("/");
}
