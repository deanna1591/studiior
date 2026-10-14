"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { renderBody } from "@/lib/email-body";

// Decision 78c — per-studio template overrides, edited in the shared composer.
// render_notification prefers an override; the markup is parsed once here (Next),
// never in SQL. All three run under the manager-up RLS on the table.

export type TplResult = { ok: true; sentence?: string } | { error: string };

export async function saveTemplateOverride(key: string, subject: string, body: string): Promise<TplResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  if (!subject.trim() || !body.trim()) return { error: "Give the email a subject and a body." };
  const r = renderBody(body);
  const supabase = createClient();
  const { data, error } = await supabase.from("notification_templates_overrides")
    .upsert({ studio_id: ctx.studioId, key, subject, body, body_html: r.html,
              updated_by: ctx.userId, updated_at: new Date().toISOString() })
    .select("key");
  if (error) return { error: error.message };
  if (!data?.length) return { error: "Nothing was saved. Owners and managers only." };
  revalidatePath(`/settings/templates/${key}`); revalidatePath("/settings/templates");
  return { ok: true, sentence: "Saved. This studio's members now get your version." };
}

export async function resetTemplateOverride(key: string): Promise<TplResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const supabase = createClient();
  const { error } = await supabase.from("notification_templates_overrides")
    .delete().eq("studio_id", ctx.studioId).eq("key", key);
  if (error) return { error: error.message };
  revalidatePath(`/settings/templates/${key}`); revalidatePath("/settings/templates");
  return { ok: true, sentence: "Reset to the default wording." };
}

// Send me a test: save the on-screen wording first (so the test shows exactly
// what members would get — render_notification reads the override), then queue
// one notification to the caller's own staff email via the SECURITY DEFINER RPC
// (clients cannot INSERT into notifications). This is the campaigns save-then-test
// shape.
export async function sendTemplateTest(key: string, subject: string, body: string): Promise<TplResult> {
  const saved = await saveTemplateOverride(key, subject, body);
  if ("error" in saved) return saved;
  const supabase = createClient();
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const { data, error } = await supabase.rpc("send_template_test", {
    p_studio_id: ctx.studioId, p_key: key,
  });
  if (error) return { error: error.message };
  const to = (data as { to_email?: string } | null)?.to_email;
  return { ok: true, sentence: to ? `Saved, and sent a test to ${to}.` : "Saved, and sent a test." };
}
