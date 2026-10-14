import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { TEMPLATE_GROUPS } from "@/lib/templates";

export const dynamic = "force-dynamic";

/**
 * Decision 78c — the studio's editable notification templates. Every convert,
 * keep, retention-task and closure message, grouped; each opens the shared
 * composer. A key the studio has customised is flagged, so "which of these have
 * we changed" is answerable at a glance. Manager-up (overrides are manager-up).
 */
export default async function TemplatesScreen() {
  const screen = await staffScreen("/settings/templates");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Templates"><Denied what="templates" role={ctx.role} /></AppShell>;
  }

  const { data: overrides } = await supabase
    .from("notification_templates_overrides").select("key").eq("studio_id", ctx.studioId);
  const customised = new Set((overrides ?? []).map((o: { key: string }) => o.key));

  return (
    <AppShell {...shell} title="Templates">
      <p className="mb-5 max-w-2xl text-[13px] leading-[20px] text-ink-2">
        The wording members get. Edit any of these in your own voice — your version replaces the
        default for your studio, and &ldquo;Reset to default&rdquo; brings the standard wording back.
      </p>
      {TEMPLATE_GROUPS.map((g) => (
        <section key={g.title} className="mb-6 max-w-2xl">
          <h2 className="mb-2 text-[13px] font-semibold text-ink">{g.title}</h2>
          <div className="divide-y divide-line rounded border border-line bg-surface">
            {g.keys.map((k) => (
              <Link key={k.key} href={`/settings/templates/${k.key}`}
                className="flex items-center justify-between px-3.5 py-2.5 hover:bg-paper">
                <span className="text-[13px] text-ink">{k.label}</span>
                {customised.has(k.key)
                  ? <span className="rounded bg-accent-chip px-1.5 py-0.5 text-[11px] text-ink">Customised</span>
                  : <span className="text-[12px] text-ink-3">Default</span>}
              </Link>
            ))}
          </div>
        </section>
      ))}
    </AppShell>
  );
}
