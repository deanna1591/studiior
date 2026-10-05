import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import Link from "next/link";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import OpeningHoursPanel from "../opening-hours";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

/**
 * Decision 44 — Settings → Studio. Currently the one opening window; per-weekday
 * hours and closures-by-date are deferred (the existing Closures screen is
 * unchanged).
 */
export default async function StudioSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Studio"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.from("studio_settings")
    .select("open_time, close_time").eq("studio_id", ctx.studioId).maybeSingle();

  // Postgres returns "HH:MM:SS"; a native time input wants "HH:MM".
  const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : null);

  return (
    <AppShell {...shell} title="Studio">
      <SettingsBack />
      <SectionLabel>Opening hours</SectionLabel>
      <div className="mt-3">
        <OpeningHoursPanel open={hhmm(data?.open_time)} close={hhmm(data?.close_time)} />
      </div>

      {/* Decision 35 §3 — the printed check-in QR for the wall. */}
      <div className="mt-8">
        <SectionLabel>Check-in code</SectionLabel>
        <p className="mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-3">
          A printable QR members scan to check in from their phone, inside the
          class window. Set the primary location&rsquo;s coordinates below for the
          door check to work.
        </p>
        <Link href="/settings/studio/checkin-code/print"
              className="mt-3 inline-block rounded border border-line bg-surface px-3.5 py-2 text-[14px] font-medium text-ink hover:bg-paper">
          Print check-in code →
        </Link>
      </div>
    </AppShell>
  );
}
