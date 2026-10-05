import Link from "next/link";
import type { Metadata } from "next";
import { getMemberContext } from "@/lib/auth";
import { memberScreen } from "@/lib/member";
import { anonStudio } from "@/lib/anon-studio";
import { createClient } from "@/lib/supabase/server";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney, isOnlineBuyable, INTRO_USED_SENTENCE } from "@/lib/plans";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import { buyPath } from "@/lib/member-urls";
import BuyPlan from "../../account/plan/buy";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Plan = {
  id: string; name: string; description: string | null; type: string;
  price_cents: number; currency: string; credits: number | null;
  validity_days: number | null; visibility: string; status: string;
  credits_per_period: number | null; billing_interval: string | null;
};

/** Reads the plan under the member's own RLS (plans_member_read = this studio,
 *  visibility public). Returns null for a bad UUID, a foreign/non-public plan,
 *  or a read error — never throws, so an invalid link refuses, not 500s. */
async function readPlan(supabase: ReturnType<typeof createClient>, planId: string): Promise<Plan | null> {
  if (!UUID.test(planId)) return null;
  const { data } = await supabase.from("membership_plans")
    .select("id, name, description, type, price_cents, currency, credits, validity_days, visibility, status, credits_per_period, billing_interval")
    .eq("id", planId).maybeSingle();
  return (data as Plan | null) ?? null;
}

// The exact buyability predicate from /account/plan: a one-time plan, public
// and active. (Online payment being set up — xenditEnabled — is checked
// separately so its refusal can say something different.) Decision 62: a trial
// is a one-time plan, so it is buyable here too — the intro-once check is
// separate, so its refusal can say something different.
const isBuyable = (p: Plan) =>
  isOnlineBuyable(p.type) && p.visibility === "public" && p.status === "active";

// Decision 66: a recurring plan is bought as a single period. Its "includes" is
// the per-period allowance (null = unlimited, Decision 12) plus the one line
// that says there is no auto-charge — you renew by hand.
const PERIOD_WORD: Record<string, string> = { week: "week", month: "month", year: "year" };
function recurringIncludes(p: Plan): (string | null)[] {
  const per = p.billing_interval ? PERIOD_WORD[p.billing_interval] ?? "period" : "period";
  return [
    p.credits_per_period == null ? "Unlimited classes"
      : `${p.credits_per_period} class${p.credits_per_period === 1 ? "" : "es"} a ${per}`,
    `one ${per} — renew by hand`,
  ];
}

export async function generateMetadata({ params }: { params: { plan: string } }): Promise<Metadata> {
  const studio = await anonStudio();
  const studioName = studio?.name ?? "";
  let planName: string | null = null;
  try {
    const ctx = await getMemberContext();
    if (ctx && UUID.test(params.plan)) {
      const p = await readPlan(createClient(), params.plan);
      if (p && isBuyable(p)) planName = p.name;
    }
  } catch {
    /* metadata is best-effort; fall back to the studio name */
  }
  const title = planName ? `${planName} — ${studioName}` : studioName ? `Buy — ${studioName}` : "Buy";
  return { title };
}

export default async function Buy({ params }: { params: { plan: string } }) {
  const next = buyPath(params.plan);
  const ctx = await getMemberContext();

  // --- Signed out (or a session with no member row for this studio) ----------
  // A standalone themed frame, NOT MemberShell: the tab bar would offer a
  // signed-out visitor screens that all bounce to /login. Sign in / Create
  // account carry ?next so they land back here (Decision 41).
  if (!ctx) {
    const studio = await anonStudio();
    const preset = (studio?.theme_preset ?? "warm") as PresetKey;
    const accent = studio?.accent_color ?? neutralAccent(preset);
    const vars = themeVars(preset, accent) as React.CSSProperties;
    return (
      <div className="m-page min-h-screen" style={vars}>
        <main className="mx-auto flex min-h-screen max-w-lg flex-col items-center justify-center px-5 text-center">
          {studio?.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={studio.logo_url} alt="" className="mb-5 h-16 w-16 rounded-2xl object-contain" />
          ) : null}
          {studio?.name && <p className="m-head text-[22px] leading-7 text-ink">{studio.name}</p>}
          <p className="m-body mt-2 text-ink-2">Sign in or create your account to buy this plan.</p>
          <div className="mt-6 w-full max-w-xs space-y-3">
            <Link href={`/login?next=${encodeURIComponent(next)}`}
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                  className="m-action m-press flex w-full items-center justify-center rounded-xl text-[16px] font-semibold">
              Sign in
            </Link>
            <Link href={`/signup?next=${encodeURIComponent(next)}`}
                  className="m-action m-press flex w-full items-center justify-center rounded-xl border border-line-2 bg-surface text-[16px] font-semibold text-ink">
              Create an account
            </Link>
          </div>
        </main>
      </div>
    );
  }

  // --- Signed in -------------------------------------------------------------
  const { supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl, settings } =
    await memberScreen();
  const plan = await readPlan(supabase, params.plan);

  const Frame = ({ children }: { children: React.ReactNode }) => (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account/plan" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Plans
      </Link>
      {children}
    </MemberShell>
  );

  const unavailable = (
    <Frame>
      <div className="m-card p-5 text-center">
        <p className="m-body text-ink">This plan isn&rsquo;t available online. Ask the studio.</p>
        <p className="m-sub mt-1 text-ink-2">
          <Link href="/account/plan" className="text-lime-text underline underline-offset-4">See the plans</Link>.
        </p>
      </div>
    </Frame>
  );

  if (!plan || !isBuyable(plan)) return unavailable;

  if (!settings.xenditEnabled) {
    return (
      <Frame>
        <section className="m-card p-5">
          <h1 className="m-head text-[24px] leading-8 text-ink">{plan.name}</h1>
          <p className="m-body mt-3 text-ink">Online payment isn&rsquo;t set up yet — pay at the studio.</p>
        </section>
      </Frame>
    );
  }

  // What the plan includes and its expiry rule, mirroring /account/plan.
  const includes = plan.type === "recurring"
    ? recurringIncludes(plan)
    : plan.type === "drop_in"
    ? ["Single class", plan.validity_days ? `use within ${plan.validity_days} days` : null]
    // class_pack and trial are both a count of classes over a window.
    : [plan.credits != null ? `${plan.credits} class${plan.credits === 1 ? "" : "es"}` : null,
       plan.validity_days ? `use within ${plan.validity_days} days` : null];

  // Decision 62: an intro offer is bought once per person. Show the sentence in
  // place of Buy when this member has already had the studio's trial. The
  // database refuses either way (activate_purchase / xendit_begin_purchase); the
  // screen just says why before the member taps.
  const introUsed = plan.type === "trial" && settings.trialUsed;

  // Decision 57: a second pack is a legitimate purchase — say so when they
  // already hold this plan live. Decision 24: a capped plan that is full takes
  // no NEW place online (plan_seats, the member-callable reader). A renewal is
  // never a new place and is never gated — begin treats a recurring plan the
  // member already holds (active/past_due) as a renewal and skips the cap, so
  // this screen must too, or it would hide the Buy a renewal needs.
  const [{ data: held }, { data: seats }] = await Promise.all([
    supabase.from("memberships")
      .select("status").eq("member_id", ctx.memberId).eq("plan_id", plan.id)
      .not("status", "in", "(cancelled,expired)"),
    supabase.rpc("plan_seats", { p_studio_id: ctx.studioId }),
  ]);
  const heldRows = held ?? [];
  const alreadyHas = heldRows.length > 0;
  const isRenewal = plan.type === "recurring" &&
    heldRows.some((h) => h.status === "active" || h.status === "past_due");
  const full = !isRenewal && (seats ?? []).some((s) => s.plan_id === plan.id && s.is_full);

  return (
    <Frame>
      <section className="m-card p-5">
        <h1 className="m-head text-[24px] leading-8 text-ink">{plan.name}</h1>
        <p className="m-sub mt-1 text-ink-2">
          <span className="num">{formatMoney(plan.price_cents, plan.currency)}</span>
        </p>
        {plan.description && <p className="m-body mt-3 text-ink">{plan.description}</p>}
        <p className="m-sub mt-2 text-ink-3">{includes.filter(Boolean).join(" · ")}</p>

        {alreadyHas && !introUsed && (
          <p className="m-sub mt-3 text-ink-2">
            {plan.type === "recurring"
              ? <>You already have {plan.name} — this renews it for another period.</>
              : <>You already have {plan.name} — buying again adds to it.</>}
          </p>
        )}

        {introUsed ? (
          <p className="m-sub mt-4 rounded-xl border-l-2 border-coral bg-coral-tint px-3 py-2 text-ink">
            {INTRO_USED_SENTENCE}
          </p>
        ) : full ? (
          <p className="m-sub mt-4 rounded-xl border-l-2 border-coral bg-coral-tint px-3 py-2 text-ink">
            This plan is full — ask the studio.
          </p>
        ) : (
          <div className="mt-5 flex justify-end">
            <BuyPlan planId={plan.id} />
          </div>
        )}
      </section>
    </Frame>
  );
}
