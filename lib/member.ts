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
  const b = ctx.bootstrap;

  // Everything here arrived with the member, in the same request. It used to be
  // four more: studios, studio_member_settings, the waitlist-offer count and a
  // second read of the member row for their photo — none of which could start
  // until the member lookup returned, because they all needed the studio id.
  if (b?.billing_locked) redirect("/unavailable");

  // The photograph is the one thing that still needs its own request, because
  // signing is a Storage call rather than a query. It no longer waits for a
  // batch to finish first — the path came back with the member.
  const avatarUrl = await signAvatar(supabase, b?.avatar_path);

  const displayName = b?.preferred_name?.trim() || b?.first_name || "";

  return {
    ctx,
    supabase,
    studioName: b?.studio_name ?? ctx.studioName,
    logoUrl: b?.logo_url ?? null,
    preset: (b?.theme_preset ?? "warm") as PresetKey,
    accent: b?.accent_color ?? null,
    openOffers: b?.open_offers ?? 0,
    memberName: displayName,
    memberFullName: [b?.first_name, b?.last_name].filter(Boolean).join(" "),
    avatarUrl,
    settings: {
      checkinOpensBefore: b?.checkin_opens_minutes_before ?? 60,
      checkinClosesAfter: b?.checkin_closes_minutes_after ?? 30,
      cancellationCutoff: b?.cancellation_cutoff_minutes ?? 720,
      bookingCutoff: b?.booking_cutoff_minutes ?? 0,
      waitlistEnabled: b?.waitlist_enabled ?? true,
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
