import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import PayrollPanel from "../payroll";
import ConversionPanel from "../conversion";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function PayrollSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Payroll"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const today = new Date().toISOString().slice(0, 10);
  const [{ data: settings }, { data: studio }, { data: period }] = await Promise.all([
    supabase.from("studio_settings").select("pay_period_mode, pay_period_second_day, pay_period_anchor, pay_settle_dow, pay_settle_offset_days, conversion_bonus_enabled, conversion_bonus_cents, conversion_window_days").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("studios").select("currency").eq("id", ctx.studioId).maybeSingle(),
    supabase.from("pay_periods").select("starts_on, ends_on, status").lte("starts_on", today).gte("ends_on", today).maybeSingle(),
  ]);
  const fmtDate = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));
  const closeWord = period?.ends_on ? fmtDate(period.ends_on) : null;

  // The settle date the current period would pay on, for the summary line only —
  // the database is the authority via pay_statement/pay_period_export. Mirrors
  // pay_settle_on(): the offset shape wins, else the first settle-dow after close.
  const settleDow = settings?.pay_settle_dow ?? null;
  const settleOffset = settings?.pay_settle_offset_days ?? null;
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
    <AppShell {...shell} title="Payroll">
      <SettingsBack />
      <SectionLabel>How often instructors are paid, and when</SectionLabel>
      <div className="mt-3">
        <PayrollPanel mode={settings?.pay_period_mode ?? "fortnightly"} secondDay={settings?.pay_period_second_day ?? 16}
                      settleDow={settleDow} settleOffset={settleOffset} anchor={settings?.pay_period_anchor ?? null} />
      </div>
      <p className="mt-4 max-w-xl text-[13px] leading-[20px] text-ink-2">
        {closeWord
          ? <>The current period closes on <span className="font-medium text-ink">{closeWord}</span>
              {settleWord && <>, and instructors are paid on <span className="font-medium text-ink">{settleWord}</span></>}.</>
          : <>The next period will be created when there is pay to record.</>}
        {" "}Studiior works out what is owed; it does not move money.
      </p>

      <div className="mt-8">
        <SectionLabel>Conversion bonus</SectionLabel>
        <div className="mt-3">
          <ConversionPanel enabled={settings?.conversion_bonus_enabled ?? false}
                           amountCents={settings?.conversion_bonus_cents ?? 0}
                           windowDays={settings?.conversion_window_days ?? 30}
                           currency={currency} />
        </div>
      </div>
    </AppShell>
  );
}
