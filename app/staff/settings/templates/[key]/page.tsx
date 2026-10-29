import Link from "next/link";
import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { isEditableTemplate, templateLabel, placeholdersFrom } from "@/lib/templates";
import TemplateEditor from "@/components/staff/template-editor";

export const dynamic = "force-dynamic";

/**
 * Decision 78c — edit one template in the shared composer. The default wording
 * comes from notification_templates; any saved override for this studio is what
 * is shown and edited. Placeholders are derived from the default text so they
 * match what render_notification substitutes.
 */
export default async function TemplateEditScreen({ params }: { params: { key: string } }) {
  const key = params.key;
  if (!isEditableTemplate(key)) notFound();

  const screen = await staffScreen(`/settings/templates/${key}`);
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Templates"><Denied what="templates" role={ctx.role} /></AppShell>;
  }

  const [{ data: def }, { data: ov }, { data: settings }] = await Promise.all([
    supabase.from("notification_templates").select("subject, text_body").eq("key", key).maybeSingle(),
    supabase.from("notification_templates_overrides").select("subject, body")
      .eq("studio_id", ctx.studioId).eq("key", key).maybeSingle(),
    supabase.from("studio_settings").select("disabled_templates").eq("studio_id", ctx.studioId).maybeSingle(),
  ]);

  if (!def) notFound();
  const placeholders = placeholdersFrom(def.subject, def.text_body);
  const enabled = !((settings?.disabled_templates as string[] | null) ?? []).includes(key);

  return (
    <AppShell {...shell} title={templateLabel(key)}>
      <Link href="/settings/templates" className="mb-4 inline-block text-[13px] text-ink-2 hover:text-ink">
        ← All templates
      </Link>
      <TemplateEditor
        templateKey={key}
        label={templateLabel(key)}
        defaultSubject={def.subject}
        defaultBody={def.text_body}
        overrideSubject={ov?.subject ?? null}
        overrideBody={ov?.body ?? null}
        placeholders={placeholders}
        studioName={ctx.studioName}
        enabled={enabled}
      />
    </AppShell>
  );
}
