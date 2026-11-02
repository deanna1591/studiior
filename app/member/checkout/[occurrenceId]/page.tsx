import Link from "next/link";
import { notFound } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { fmtTime, fmtDayLong } from "@/lib/time";
import { checkoutPlanOrder, planHelpLine } from "@/lib/checkout";
import CheckoutBody, { type CheckoutPlanRow } from "./checkout-body";

export const dynamic = "force-dynamic";

/**
 * Decision 88 slice A — checkout. Reached when a member taps Book on a class
 * their plan does not cover (the class page routes them here) or from the old
 * "Pay now" on an unpaid booking. They pick a class, see what it costs, and buy
 * what covers it on the same screen — no cart, no separate money place.
 *
 * Everything the screen needs already has a reader, so the only new RPC is
 * member_covers_occurrence (the coverage/routing hint); the rest is the same
 * occurrence read and the same public-plan catalogue the plans page uses.
 */
export default async function Checkout({ params }: { params: { occurrenceId: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings, openOffers, memberName, avatarUrl } =
    await memberScreen();
  const occId = params.occurrenceId;

  const [{ data: occ }, { data: covers }, { data: catalogue }, { count: activeGuests }, { data: introCfg }, { data: introWin }] =
    await Promise.all([
      // RLS occ_member_read: a scheduled, visible class only — notFound otherwise,
      // the same answer the class page gives.
      supabase.from("class_occurrences")
        .select("id, name, starts_at, ends_at, status, instructors!instructor_id(display_name)")
        .eq("id", occId).maybeSingle(),
      supabase.rpc("member_covers_occurrence", { p_occurrence_id: occId }),
      // The studio's public, active plans — RLS (plans_member_read) already
      // scopes this to this studio. Buyability + ordering is applied below.
      supabase.from("membership_plans")
        .select("id, name, type, price_cents, currency, credits, credits_per_period, validity_days, billing_interval")
        .eq("visibility", "public").eq("status", "active").order("sort_order"),
      settings.guestPassesEnabled
        ? supabase.from("guest_passes").select("id", { count: "exact", head: true })
            .eq("host_member_id", ctx.memberId).in("status", ["invited", "confirmed"])
        : Promise.resolve({ count: 0 }),
      // Decision 78: an exclusive intro offer only shows inside the window.
      supabase.from("studio_settings").select("intro_offer_plan_id, intro_offer_exclusive")
        .eq("studio_id", ctx.studioId).maybeSingle(),
      supabase.rpc("intro_window", { p_member_id: ctx.memberId }),
    ]);

  if (!occ || occ.status !== "scheduled") notFound();

  const covered = covers === true;
  const introActive = ((introWin as { active?: boolean } | null)?.active) === true;
  const hideExclusiveIntro = !!introCfg?.intro_offer_exclusive && !!introCfg?.intro_offer_plan_id && !introActive;

  // Decision 88 order: drop-in first (preselected), then the intro offer when
  // eligible, then packs, then memberships. Group plans are not a single-seat
  // purchase and are excluded.
  const ordered = checkoutPlanOrder(catalogue ?? [], {
    trialUsed: settings.trialUsed,
    introPlanId: introCfg?.intro_offer_plan_id ?? null,
    hideExclusiveIntro,
  });
  const plans: CheckoutPlanRow[] = ordered.map((p) => ({
    id: p.id, type: p.type, name: p.name,
    price_cents: p.price_cents, currency: p.currency,
    help: planHelpLine(p),
  }));

  const instructor = (occ as { instructors: { display_name: string } | null }).instructors;
  const instructorFirst = instructor?.display_name?.split(" ")[0] ?? null;
  const whenLabel = `${fmtDayLong(occ.starts_at, ctx.timeZone)} · ${fmtTime(occ.starts_at, ctx.timeZone, ctx.timeFormat)}${occ.ends_at ? `–${fmtTime(occ.ends_at, ctx.timeZone, ctx.timeFormat)}` : ""}`;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href={`/class/${occId}`} className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Class
      </Link>
      <h1 className="m-title mb-4 text-ink">Checkout</h1>

      <CheckoutBody
        occId={occId}
        className={occ.name}
        whenLabel={whenLabel}
        instructorFirst={instructorFirst}
        costLine={covered ? "Included" : "1 credit"}
        covered={covered}
        plans={plans}
        guestAvailable={settings.guestPassesEnabled && (activeGuests ?? 0) === 0}
        deskPayAvailable={ctx.bootstrap?.desk_pay_available ?? true}
      />
    </MemberShell>
  );
}
