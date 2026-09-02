import { redirect } from "next/navigation";
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

  // is_platform_admin and the billing state used to be two requests here. Both
  // arrive with the staff context now (migration 052), so what is left is the
  // setup checklist and the banner's two counts — and those no longer wait on
  // each other: the banner needed `summary.complete` only to decide whether to
  // show the setup nudge, which is a decision, not a dependency.
  const [summary, bannerCounts] = await Promise.all([
    setupSummary(supabase, ctx.studioId),
    studioBanner(supabase, ctx.studioId, true, ctx.billing),
  ]);
  const isPlatformAdmin = ctx.isPlatformAdmin;
  const billing = ctx.billing;

  // Lockout is enforced HERE rather than in middleware. Middleware would have
  // to resolve the signed-in user's studio on every request — including static
  // assets — to know which subscription to check, and this helper is the thing
  // every staff screen already goes through with the studio id in hand. It is
  // the real chokepoint; middleware would have been the decorative one.
  //
  // It is not the only enforcement either way: migration 045 gates book_class,
  // resolve_checkin_code, import_commit and record_manual_payment in the
  // database, because a permission that exists only in the app is not one.
  if (billing.locked && path !== "/billing") {
    redirect("/billing");
  }

  // The setup nudge is applied here rather than inside the banner, because it
  // is the one candidate that depended on a query running first.
  const raw = bannerCounts ?? (summary.complete ? null : {
    kind: "setup" as const,
    text: "Your studio is not finished being set up.",
    action: { href: "/setup", label: "Pick up where you left off" },
  });
  const banner = raw && path && raw.action?.href === path ? null : raw;

  return {
    gate: null,
    ctx,
    supabase,
    summary,
    banner,
    billing,
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
