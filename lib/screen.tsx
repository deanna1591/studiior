import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp, type StaffContext } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { railItems } from "@/lib/nav";
import { setupSummary } from "@/lib/setup";
import { studioBanner } from "@/lib/banner";
import { signOut } from "@/app/staff/actions";

/**
 * Everything every staff screen needs before it can draw anything: who is
 * asking, whether they are past the wizard, what the rail should offer them,
 * and a client already carrying their session.
 *
 * Returns a `gate` instead of a context when the caller is not staff — the
 * page renders that and stops. Deciding what to do about a non-staff caller
 * stays with StaffAccessGate; this only makes sure every screen asks.
 */
export async function staffScreen(path?: string) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") {
    return { gate: <StaffAccessGate access={access} />, ctx: null, supabase: null, shell: null } as const;
  }
  const ctx = requireOnboarded(access.ctx);
  const supabase = createClient();

  const [{ data: isPlatformAdmin }, summary] = await Promise.all([
    supabase.rpc("is_platform_admin"),
    setupSummary(supabase, ctx.studioId),
  ]);

  // The banner is part of the frame, so it follows you rather than living on
  // one screen. It is dropped when it would point at the screen you are
  // already looking at — "finish setting up" on the setup page is noise.
  // Matched whole, query included. Comparing paths alone hid the failed-payment
  // banner on /members — but its link goes to /members?filter=payment, and
  // standing on the unfiltered list is not the same as having seen who.
  const raw = await studioBanner(supabase, ctx.studioId, summary.complete);
  const banner = raw && path && raw.action?.href === path ? null : raw;

  return {
    gate: null,
    ctx,
    supabase,
    summary,
    banner,
    shell: {
      ...shellProps(ctx, isPlatformAdmin === true, summary.complete),
      banner,
    },
  } as const;
}

export function shellProps(ctx: StaffContext, isPlatformAdmin: boolean, setupComplete: boolean) {
  return {
    studioName: ctx.studioName,
    location: ctx.locationName,
    items: railItems(ctx, isPlatformAdmin, !setupComplete && isManagerUp(ctx.role)),
    user: { email: ctx.email, role: ctx.role },
    signOut: (
      <form action={signOut}>
        <button className="text-[12px] leading-4 text-ink-3 underline underline-offset-4 hover:text-ink">
          Sign out
        </button>
      </form>
    ),
  };
}
