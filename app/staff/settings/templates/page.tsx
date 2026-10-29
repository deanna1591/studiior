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

  const [{ data: overrides }, { data: existing }, { data: settings }] = await Promise.all([
    supabase.from("notification_templates_overrides").select("key").eq("studio_id", ctx.studioId),
    supabase.from("notification_templates").select("key"),
    supabase.from("studio_settings").select("disabled_templates").eq("studio_id", ctx.studioId).maybeSingle(),
  ]);
  const customised = new Set((overrides ?? []).map((o: { key: string }) => o.key));
  // Only show keys that actually exist as templates — the grouped list names the
  // whole member/instructor set, but a studio only has the ones seeded for it.
  const present = new Set((existing ?? []).map((t: { key: string }) => t.key));
  const disabled = new Set(((settings?.disabled_templates as string[] | null) ?? []));

  const groups = TEMPLATE_GROUPS
    .map((g) => ({ ...g, keys: g.keys.filter((k) => present.has(k.key)) }))
    .filter((g) => g.keys.length > 0);

  return (
    <AppShell {...shell} title="Templates">
      <p className="mb-5 max-w-2xl text-[13px] leading-[20px] text-ink-2">
        The wording members get. Edit any of these in your own voice — your version replaces the
        default for your studio, and &ldquo;Reset to default&rdquo; brings the standard wording back.
        You can also switch any one email off on its own screen.
      </p>
      {groups.map((g) => (
        <section key={g.title} className="mb-6 max-w-2xl">
          <h2 className="mb-2 text-[13px] font-semibold text-ink">{g.title}</h2>
          <div className="divide-y divide-line rounded border border-line bg-surface">
            {g.keys.map((k) => (
              <Link key={k.key} href={`/settings/templates/${k.key}`}
                className="flex items-center justify-between px-3.5 py-2.5 hover:bg-paper">
                <span className="text-[13px] text-ink">{k.label}</span>
                <span className="flex items-center gap-2">
                  {disabled.has(k.key) && (
                    <span className="rounded bg-paper px-1.5 py-0.5 text-[11px] text-ink-2">Off</span>
                  )}
                  {customised.has(k.key)
                    ? <span className="rounded bg-accent-chip px-1.5 py-0.5 text-[11px] text-ink">Customised</span>
                    : <span className="text-[12px] text-ink-3">Default</span>}
                </span>
              </Link>
            ))}
          </div>
        </section>
      ))}
    </AppShell>
  );
}
