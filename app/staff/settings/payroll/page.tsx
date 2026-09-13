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
    supabase.from("studio_settings").select("pay_period_mode, pay_period_second_day").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("pay_periods").select("starts_on, ends_on, status").lte("starts_on", today).gte("ends_on", today).maybeSingle(),
  ]);
  const closeWord = period?.ends_on
    ? new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(new Date(`${period.ends_on}T00:00:00Z`))
    : null;

  return (
    <AppShell {...shell} title="Payroll">
      <SettingsBack />
      <SectionLabel>How often instructors are paid</SectionLabel>
      <div className="mt-3">
        <PayrollPanel mode={settings?.pay_period_mode ?? "fortnightly"} secondDay={settings?.pay_period_second_day ?? 16} />
      </div>
      <p className="mt-4 max-w-xl text-[13px] leading-[20px] text-ink-2">
        {closeWord
          ? <>The current period closes on <span className="font-medium text-ink">{closeWord}</span>.</>
          : <>The next period will be created when there is pay to record.</>}
        {" "}Studiior works out what is owed; it does not move money.
      </p>
    </AppShell>
  );
}
