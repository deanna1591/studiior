import Link from "next/link";
import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { isEditableTemplate, templateLabel, templateEntry, placeholdersFrom, templateFeature } from "@/lib/templates";
import TemplateEditor from "@/components/staff/template-editor";

const FEATURE_LABEL: Record<string, string> = {
  flex: "flex classes", free_first: "free first class", guest_passes: "guest passes",
  challenges: "challenges", shop: "the shop", guarantees: "class guarantees",
};

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

  const [{ data: def }, { data: ov }, { data: settings }, { count: productCount }] = await Promise.all([
    supabase.from("notification_templates").select("subject, text_body").eq("key", key).maybeSingle(),
    supabase.from("notification_templates_overrides").select("subject, body")
      .eq("studio_id", ctx.studioId).eq("key", key).maybeSingle(),
    supabase.from("studio_settings")
      .select("disabled_templates, flex_enabled, free_first_class_enabled, guest_passes_enabled, challenges_enabled, guarantees_enabled")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("products").select("id", { count: "exact", head: true }).eq("studio_id", ctx.studioId),
  ]);

  if (!def) notFound();
  const placeholders = placeholdersFrom(def.subject, def.text_body);
  const enabled = !((settings?.disabled_templates as string[] | null) ?? []).includes(key);

  // A template whose feature is off is hidden from the lists; reached directly it
  // says so rather than editing/previewing with context the studio does not use.
  // (This is also what keeps free-first / flex sample context out of the preview
  // for those keys — the editor and its preview do not render while off.)
  const feature = templateFeature(key);
  const featureOn: Record<string, boolean> = {
    flex: settings?.flex_enabled ?? false,
    free_first: settings?.free_first_class_enabled ?? false,
    guest_passes: settings?.guest_passes_enabled ?? false,
    challenges: settings?.challenges_enabled ?? false,
    shop: (productCount ?? 0) > 0,
    guarantees: settings?.guarantees_enabled ?? false,
  };
  if (feature && !featureOn[feature]) {
    return (
      <AppShell {...shell} title={templateLabel(key)}>
        <Link href="/settings/templates" className="mb-4 inline-block text-[13px] text-ink-2 hover:text-ink">
          ← All templates
        </Link>
        <p className="max-w-2xl text-[13px] leading-[20px] text-ink-2">
          This email belongs to <span className="font-medium text-ink">{FEATURE_LABEL[feature] ?? feature}</span>,
          which is off for your studio, so it is not sent. Turn that feature on to edit it. Your wording and
          its on/off switch are kept.
        </p>
      </AppShell>
    );
  }

  return (
    <AppShell {...shell} title={templateLabel(key)}>
      <Link href="/settings/templates" className="mb-4 inline-block text-[13px] text-ink-2 hover:text-ink">
        ← All templates
      </Link>
      {(() => {
        const e = templateEntry(key);
        return e ? (
          <p className="mb-4 max-w-2xl text-[13px] leading-[19px] text-ink-2">
            <span className="font-medium text-ink">{e.audience}</span> · {e.when}
          </p>
        ) : null;
      })()}
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
