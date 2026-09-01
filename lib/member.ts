import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { signAvatar } from "@/lib/avatars";
import { getMemberContext } from "@/lib/auth";
import type { PresetKey } from "@/lib/theme";

/**
 * Everything a member screen needs before it draws: who they are, what their
 * studio is called, and the handful of settings the app is allowed to know.
 *
 * The settings come from studio_member_settings() rather than the table: RLS
 * is row-level, so a read policy on studio_settings would also hand over every
 * fee, the morning brief time and the onboarding state.
 */
export async function memberScreen() {
  const ctx = await getMemberContext();
  if (!ctx) redirect("/login");

  const supabase = createClient();
  const [{ data: studio }, { data: settings }, { count: offerCount }, { data: me }] = await Promise.all([
    supabase.from("studios").select("name, logo_url, theme_preset, accent_color").eq("id", ctx.studioId).maybeSingle(),
    supabase.rpc("studio_member_settings", { p_studio_id: ctx.studioId }),
    // A live waitlist offer is the one number in this app that is worth a
    // badge: it expires, and if the member does not answer it goes to the next
    // person. A count of upcoming bookings would be a badge on something
    // nobody has to do anything about, which teaches people to ignore badges.
    supabase
      .from("waitlist_offers")
      .select("id, bookings!inner(member_id)", { count: "exact", head: true })
      .is("responded_at", null)
      .gt("expires_at", new Date().toISOString())
      .eq("bookings.member_id", ctx.memberId),
    supabase
      .from("members")
      .select("first_name, last_name, preferred_name, avatar_url")
      .eq("id", ctx.memberId)
      .maybeSingle(),
  ]);

  // preferred_name first: it is what they asked to be called, and the greeting
  // is the one place in the app that speaks to them rather than about them.
  const displayName = me?.preferred_name?.trim() || me?.first_name || "";
  // members.avatar_url holds an object path, not a URL — the bucket is private.
  const avatarUrl = await signAvatar(supabase, me?.avatar_url);

  const s = Array.isArray(settings) ? settings[0] : settings;

  return {
    ctx,
    supabase,
    studioName: studio?.name ?? "",
    logoUrl: studio?.logo_url ?? null,
    openOffers: offerCount ?? 0,
    memberName: displayName,
    memberFullName: [me?.first_name, me?.last_name].filter(Boolean).join(" "),
    avatarUrl,
    preset: (studio?.theme_preset ?? "warm") as PresetKey,
    accent: studio?.accent_color ?? null,
    settings: {
      checkinOpensBefore: s?.checkin_opens_minutes_before ?? 60,
      checkinClosesAfter: s?.checkin_closes_minutes_after ?? 30,
      cancellationCutoff: s?.cancellation_cutoff_minutes ?? 720,
      bookingCutoff: s?.booking_cutoff_minutes ?? 0,
      waitlistEnabled: s?.waitlist_enabled ?? true,
    },
  };
}

/** Their live membership and what is left on it. */
export async function membershipState(
  supabase: ReturnType<typeof createClient>,
  memberId: string,
) {
  const { data } = await supabase
    .from("memberships")
    .select("id, status, price_cents, currency, starts_on, expires_on, renews_on, credits_remaining, auto_renew, membership_plans(name, type)")
    .eq("member_id", memberId)
    .order("starts_on", { ascending: false });

  const live = (data ?? []).find((m) => !["cancelled", "expired"].includes(m.status));
  return { live: live ?? null, all: data ?? [] };
}
