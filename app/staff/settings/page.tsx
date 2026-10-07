import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { GROUPS, SETTINGS } from "@/lib/settings-registry";
import SettingsSearch from "@/components/staff/settings-search";

export const dynamic = "force-dynamic";

/**
 * Decision 71 — Settings home: one search box, then the six groups as a single
 * vertical list. Per group a heading + one-line description, then one row per
 * section (label links to the page + section; a muted summary on the right).
 * Owner-only sections are greyed with "Owner only" for a manager.
 */
export default async function Settings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Settings"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  const owner = ctx.role === "owner";
  // A section is owner-only when an entry under it is owner-only (Stripe, Xendit).
  const ownerOnly = new Set(
    SETTINGS.filter((s) => s.ownerOnly).map((s) => `${s.group}:${s.anchor}`),
  );

  return (
    <AppShell {...shell} title="Settings">
      <div className="mb-8 max-w-2xl">
        <SettingsSearch />
      </div>

      <div className="max-w-2xl space-y-8">
        {GROUPS.map((g) => (
          <section key={g.id}>
            <h2 className="text-[11px] font-semibold uppercase tracking-wide text-ink-3">{g.label}</h2>
            <p className="mt-0.5 text-[12px] leading-[17px] text-ink-3">{g.description}</p>
            <ul className="s-card mt-2.5 divide-y divide-line overflow-hidden">
              {g.sections.map((sec) => {
                const locked = !owner && ownerOnly.has(`${g.id}:${sec.anchor}`);
                return (
                  <li key={sec.anchor} className="flex items-baseline justify-between gap-4 px-4 py-3.5">
                    {locked ? (
                      <span className="shrink-0 whitespace-nowrap text-[14px] font-medium text-ink-3">{sec.title}</span>
                    ) : (
                      <Link href={`${g.route}#${sec.anchor}`}
                            className="shrink-0 whitespace-nowrap text-[14px] font-medium text-ink hover:underline">
                        {sec.title}
                      </Link>
                    )}
                    <span className="min-w-0 truncate text-right text-[12px] leading-[18px] text-ink-3">
                      {locked ? "Owner only" : sec.summary}
                    </span>
                  </li>
                );
              })}
            </ul>
          </section>
        ))}
      </div>
    </AppShell>
  );
}
