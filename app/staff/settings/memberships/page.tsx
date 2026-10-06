import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import PayrollPanel from "../payroll";
import ConversionPanel from "../conversion";
import SeatCapsPanel from "../seat-caps";
import HowToBuyPanel from "../how-to-buy";
import FreeFirstPanel from "../free-first";
import GuestPassesPanel from "../guest-passes";
import ChallengesPanel from "../challenges";
import SettingsBack from "../back";
import SettingsSection from "@/components/staff/settings-section";
import SettingsSummaryRow from "@/components/staff/settings-summary";

export const dynamic = "force-dynamic";

/** Decision 71 — Memberships & payments group: instructor pay, conversion bonus,
 *  plan caps, how members buy, free first classes, guests, challenges; plans are
 *  standalone on the Plans screen. */
export default async function MembershipSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Memberships & payments"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const today = new Date().toISOString().slice(0, 10);
  const [{ data: s }, { data: studio }, { data: period }, { count: capped }, { count: challengeCount }] = await Promise.all([
    supabase.from("studio_settings")
      .select("pay_period_mode, pay_period_second_day, pay_period_anchor, pay_settle_dow, pay_settle_offset_days, conversion_bonus_enabled, conversion_bonus_cents, conversion_window_days, seat_caps_enabled, how_to_buy, free_first_class_enabled, free_first_peak_allowed, free_first_core_only, free_first_seats_per_class, free_first_confirm_at, guest_passes_enabled, challenges_enabled")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("studios").select("currency").eq("id", ctx.studioId).maybeSingle(),
    supabase.from("pay_periods").select("starts_on, ends_on, status").lte("starts_on", today).gte("ends_on", today).maybeSingle(),
    supabase.from("membership_plans").select("id", { count: "exact", head: true }).eq("studio_id", ctx.studioId).not("max_active_members", "is", null),
    supabase.from("challenges").select("id", { count: "exact", head: true }).eq("studio_id", ctx.studioId).eq("audience", "member").limit(1),
  ]);

  const fmtDate = (iso: string) => new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));
  const closeWord = period?.ends_on ? fmtDate(period.ends_on) : null;
  const settleDow = s?.pay_settle_dow ?? null;
  const settleOffset = s?.pay_settle_offset_days ?? null;
  let settleWord: string | null = null;
  if (period?.ends_on && settleOffset !== null) {
    const d = new Date(`${period.ends_on}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + settleOffset);
    settleWord = fmtDate(d.toISOString().slice(0, 10));
  } else if (period?.ends_on && settleDow !== null) {
    const end = new Date(`${period.ends_on}T00:00:00Z`);
    const start = new Date(end); start.setUTCDate(start.getUTCDate() + 1);
    const offset = (settleDow - start.getUTCDay() + 7) % 7;
    const settle = new Date(start); settle.setUTCDate(settle.getUTCDate() + offset);
    settleWord = fmtDate(settle.toISOString().slice(0, 10));
  }
  const currency = studio?.currency ?? "";

  return (
    <AppShell {...shell} title="Memberships & payments">
      <SettingsBack />

      <SettingsSection id="pay-schedule" title="Instructor pay">
        <PayrollPanel mode={s?.pay_period_mode ?? "fortnightly"} secondDay={s?.pay_period_second_day ?? 16}
          settleDow={settleDow} settleOffset={settleOffset} anchor={s?.pay_period_anchor ?? null} />
        <p className="mt-4 max-w-xl text-[13px] leading-[20px] text-ink-2">
          {closeWord
            ? <>The current period closes on <span className="font-medium text-ink">{closeWord}</span>
                {settleWord && <>, and instructors are paid on <span className="font-medium text-ink">{settleWord}</span></>}.</>
            : <>The next period will be created when there is pay to record.</>}
          {" "}Studiior works out what is owed; it does not move money.
        </p>
      </SettingsSection>

      <SettingsSection id="conversion" title="Conversion bonus">
        <ConversionPanel enabled={s?.conversion_bonus_enabled ?? false}
          amountCents={s?.conversion_bonus_cents ?? 0} windowDays={s?.conversion_window_days ?? 30} currency={currency} />
      </SettingsSection>

      <SettingsSection id="seat-caps" title="Places on a plan">
        <SeatCapsPanel enabled={s?.seat_caps_enabled ?? false} capped={capped ?? 0} />
      </SettingsSection>

      <SettingsSection id="how-to-buy" title="How members buy">
        <HowToBuyPanel value={s?.how_to_buy ?? null} />
      </SettingsSection>

      <SettingsSection id="free-first" title="First class free">
        <FreeFirstPanel enabled={s?.free_first_class_enabled ?? false}
          peakAllowed={s?.free_first_peak_allowed ?? true} coreOnly={s?.free_first_core_only ?? false}
          seatsPerClass={s?.free_first_seats_per_class ?? null} confirmAt={s?.free_first_confirm_at ?? null} />
      </SettingsSection>

      <SettingsSection id="guest-passes" title="Guest passes">
        <GuestPassesPanel enabled={s?.guest_passes_enabled ?? false} />
      </SettingsSection>

      <SettingsSection id="challenges" title="Challenges">
        <ChallengesPanel enabled={s?.challenges_enabled ?? false} hasChallenges={(challengeCount ?? 0) > 0} />
      </SettingsSection>

      <SettingsSection id="plans" title="Membership plans">
        <SettingsSummaryRow title="Membership plans"
          state="Create and edit the plans members buy — price, credits, limits and who can see them."
          href="/plans" cta="Open plans" />
      </SettingsSection>
    </AppShell>
  );
}
