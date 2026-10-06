import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { GROUPS } from "@/lib/settings-registry";
import SettingsSearch from "@/components/staff/settings-search";

export const dynamic = "force-dynamic";

/**
 * Decision 71 — Settings is a home page: one search box over the whole registry,
 * then six group cards, each listing its sections as links. The old flat
 * 14-link list is gone; each group is now ONE scrolling page.
 */
export default async function Settings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Settings"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  return (
    <AppShell {...shell} title="Settings">
      <div className="mb-6">
        <SettingsSearch />
      </div>

      <div className="grid max-w-4xl gap-3 sm:grid-cols-2">
        {GROUPS.map((g) => (
          <div key={g.id} className="s-card overflow-hidden p-4">
            <Link href={g.route} className="text-[15px] font-semibold text-ink hover:underline">
              {g.label}
            </Link>
            <p className="mt-0.5 text-[12px] leading-[17px] text-ink-3">{g.description}</p>
            <ul className="mt-2.5 flex flex-wrap gap-x-3 gap-y-1">
              {g.sections.map((s) => (
                <li key={s.anchor}>
                  <Link href={`${g.route}#${s.anchor}`}
                        className="text-[12.5px] text-ink-2 underline decoration-line underline-offset-2 hover:text-ink">
                    {s.title}
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </AppShell>
  );
}
