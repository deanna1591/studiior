import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import PayrollPanel from "../payroll";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function PayrollSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Payroll"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const today = new Date().toISOString().slice(0, 10);
  const [{ data: settings }, { data: period }] = await Promise.all([
    supabase.from("studio_settings").select("pay_period_mode, pay_period_second_day, pay_settle_dow").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("pay_periods").select("starts_on, ends_on, status").lte("starts_on", today).gte("ends_on", today).maybeSingle(),
  ]);
  const fmtDate = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));
  const closeWord = period?.ends_on ? fmtDate(period.ends_on) : null;
  // The settle date the current period would pay on — the first settle-dow
  // strictly after its ends_on. Computed here only to show it; the database is
  // the authority via pay_statement/pay_period_export.
  const settleDow = settings?.pay_settle_dow ?? null;
  let settleWord: string | null = null;
  if (period?.ends_on && settleDow !== null) {
    const end = new Date(`${period.ends_on}T00:00:00Z`);
    const start = new Date(end); start.setUTCDate(start.getUTCDate() + 1);
    const offset = (settleDow - start.getUTCDay() + 7) % 7;
    const settle = new Date(start); settle.setUTCDate(settle.getUTCDate() + offset);
    settleWord = fmtDate(settle.toISOString().slice(0, 10));
  }

  return (
    <AppShell {...shell} title="Payroll">
      <SettingsBack />
      <SectionLabel>How often instructors are paid</SectionLabel>
      <div className="mt-3">
        <PayrollPanel mode={settings?.pay_period_mode ?? "fortnightly"} secondDay={settings?.pay_period_second_day ?? 16}
                      settleDow={settleDow} />
      </div>
      <p className="mt-4 max-w-xl text-[13px] leading-[20px] text-ink-2">
        {closeWord
          ? <>The current period closes on <span className="font-medium text-ink">{closeWord}</span>
              {settleWord && <>, and instructors are paid on <span className="font-medium text-ink">{settleWord}</span></>}.</>
          : <>The next period will be created when there is pay to record.</>}
        {" "}Studiior works out what is owed; it does not move money.
      </p>
    </AppShell>
  );
}
