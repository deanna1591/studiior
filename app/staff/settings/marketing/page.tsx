import Link from "next/link";
import { staffScreen } from "@/lib/screen";
import { isDeskUp } from "@/lib/auth";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

/**
 * Settings → Marketing (Decision 93). Slice 1 holds only the Brand kit; the
 * Schedule posts and Connected accounts sections arrive in slices 2–3. Desk-up
 * may open it (front desk sees the brand kit read-only).
 */
export default async function MarketingSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;
  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Marketing"><Denied what="Marketing" role={ctx.role} /></AppShell>;
  }

  return (
    <AppShell {...shell} title="Marketing">
      <SettingsBack />
      <SectionLabel>Marketing</SectionLabel>
      <p className="mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        Your studio&rsquo;s look for social posts of the timetable.
      </p>

      <div id="brand-kit" className="mt-3 max-w-2xl rounded-lg border border-line bg-surface">
        <Link href="/settings/marketing/brand-kit" className="block px-4 py-3.5 hover:bg-paper">
          <p className="text-[14px] font-medium text-ink">Brand kit</p>
          <p className="mt-0.5 text-[13px] text-ink-2">
            Learn your studio&rsquo;s look from reference designs, for timetable posts.
          </p>
        </Link>
      </div>
    </AppShell>
  );
}
