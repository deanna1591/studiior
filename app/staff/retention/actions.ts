"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { renderBody } from "@/lib/email-body";
import { buildPrompt, buildBulkPrompt, parseDraft, parseApiResponse } from "@/lib/ai-draft";

// Decision 79a — the retention panel's actions. Every write goes through a
// role-checked RPC (the page is manager-up or a routed front desk), so a stale
// page can only fail, never act around the gate.

/** The side-panel snapshot for one member. */
export async function fetchSnapshot(memberId: string) {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("member_snapshot", { p_member_id: memberId });
  if (error) return null;
  return data as Record<string, unknown>;
}

/** The effective retention_<situation> template (override or default), as the
 *  composer's markup text. `rendered` substitutes this member's placeholders;
 *  raw (bulk) keeps them so each member is rendered at send time. */
async function effectiveTemplate(studioId: string, situation: string) {
  const supabase = createClient();
  const key = `retention_${situation}`;
  const [{ data: def }, { data: ov }] = await Promise.all([
    supabase.from("notification_templates").select("subject, text_body").eq("key", key).maybeSingle(),
    supabase.from("notification_templates_overrides").select("subject, body")
      .eq("studio_id", studioId).eq("key", key).maybeSingle(),
  ]);
  return {
    subject: ov?.subject ?? def?.subject ?? "",
    body: ov?.body ?? def?.text_body ?? "",
  };
}

function fill(text: string, ctx: Record<string, string>) {
  return Object.entries(ctx).reduce(
    (acc, [k, v]) => acc.split(`{${k}}`).join(v ?? ""), text);
}

/** Pre-fill for ONE member: the template rendered with their own fields. */
export async function prefillEmail(studioId: string, memberId: string, situation: string) {
  const supabase = createClient();
  const [tpl, { data: ctx }] = await Promise.all([
    effectiveTemplate(studioId, situation),
    supabase.rpc("retention_email_context", { p_member_id: memberId, p_situation: situation }),
  ]);
  const c = (ctx ?? {}) as Record<string, string>;
  return { subject: fill(tpl.subject, c), body: fill(tpl.body, c) };
}

/** Pre-fill for a BULK send: the raw template, placeholders intact. */
export async function prefillBulk(studioId: string, situation: string) {
  return effectiveTemplate(studioId, situation);
}

export async function sendEmail(memberId: string, situation: string, subject: string, body: string) {
  const supabase = createClient();
  const { html, text } = renderBody(body);
  const { data, error } = await supabase.rpc("send_retention_email", {
    p_member_id: memberId, p_situation: situation,
    p_subject: subject, p_body_html: html, p_body_text: text,
  });
  revalidatePath("/retention");
  if (error) return { ok: false, reason: error.message };
  return data as { ok: boolean; reason?: string };
}

export async function sendBulk(
  studioId: string, memberIds: string[], situation: string, subject: string, body: string) {
  const supabase = createClient();
  const { html, text } = renderBody(body);
  const { data, error } = await supabase.rpc("send_retention_email_bulk", {
    p_member_ids: memberIds, p_situation: situation,
    p_subject: subject, p_body_html: html, p_body_text: text,
  });
  revalidatePath("/retention");
  if (error) return { sent: 0, skipped: [], error: error.message };
  return data as { sent: number; skipped: { member: string; reason: string }[] };
}

export async function sendTest(
  studioId: string, subject: string, body: string,
): Promise<{ ok: boolean; to?: string; error?: string }> {
  const supabase = createClient();
  const { html, text } = renderBody(body);
  const { data, error } = await supabase.rpc("send_retention_test", {
    p_studio_id: studioId, p_subject: subject, p_body_html: html, p_body_text: text,
  });
  if (error) return { ok: false, error: error.message };
  return data as { ok: boolean; to?: string };
}

export async function logContact(memberId: string, situation: string, method: string) {
  const supabase = createClient();
  await supabase.rpc("record_contact", { p_member_id: memberId, p_situation: situation, p_method: method });
  revalidatePath("/retention");
  revalidatePath("/");
}

export async function snooze(taskId: string | null, memberId: string, situation: string, days: number) {
  const supabase = createClient();
  await supabase.rpc("snooze_task", {
    // p_task_id accepts null (no task yet → a follow_up is created); the generated
    // arg type is non-null, so pass null through.
    p_task_id: taskId as unknown as string,
    p_member_id: memberId, p_situation: situation, p_days: days,
  });
  revalidatePath("/retention");
}

export async function dismiss(taskId: string) {
  const supabase = createClient();
  await supabase.rpc("dismiss_task", { p_task_id: taskId });
  revalidatePath("/retention");
  revalidatePath("/");
}

// Decision 79b — AI drafts. Opt-in (the toggle), capped per studio per month, and
// only when the platform key is set. The key is read ONLY from process.env here,
// on the server, inside this "use server" module — never returned, never logged,
// never in the client bundle. Refusals come back as reasons; nothing is sent.
export async function draftRetentionEmail(
  studioId: string, memberId: string, situation: string,
  currentSubject: string, currentBody: string,
): Promise<{ ok: boolean; subject?: string; body?: string; reason?: string }> {
  const supabase = createClient();
  const { data: gate, error } = await supabase.rpc("ai_draft_gate", { p_studio_id: studioId });
  if (error) return { ok: false, reason: "off" };
  const g = gate as { enabled: boolean; voice: string | null; model: string; cap: number; used: number };
  if (!g?.enabled) return { ok: false, reason: "off" };
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return { ok: false, reason: "not_configured" };
  if ((g.used ?? 0) >= (g.cap ?? 200)) return { ok: false, reason: "cap" };

  const { data: ctx } = await supabase.rpc("retention_email_context", {
    p_member_id: memberId, p_situation: situation,
  });
  const { system, user } = buildPrompt(
    (ctx ?? {}) as Record<string, string>, g.voice, currentSubject, currentBody, situation);

  let json: unknown;
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15_000);
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: g.model, max_tokens: 600, system, messages: [{ role: "user", content: user }] }),
      signal: ctrl.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return { ok: false, reason: "model_error" };
    json = await res.json();
  } catch {
    return { ok: false, reason: "model_error" };
  }

  const { text, inputTokens, outputTokens } = parseApiResponse(json);
  const draft = parseDraft(text);
  if (!draft) return { ok: false, reason: "unreadable" };

  await supabase.rpc("record_ai_draft", {
    p_studio_id: studioId, p_member_id: memberId, p_situation: situation,
    p_model: g.model, p_input_tokens: inputTokens as unknown as number, p_output_tokens: outputTokens as unknown as number,
  });
  return { ok: true, subject: draft.subject, body: draft.body };
}

/** The bulk variant: rewrite the shared template in the studio voice, KEEPING the
 *  {placeholders} (no one member). Usage is logged with member_id null. */
export async function draftRetentionBulk(
  studioId: string, situation: string, currentSubject: string, currentBody: string,
): Promise<{ ok: boolean; subject?: string; body?: string; reason?: string }> {
  const supabase = createClient();
  const { data: gate, error } = await supabase.rpc("ai_draft_gate", { p_studio_id: studioId });
  if (error) return { ok: false, reason: "off" };
  const g = gate as { enabled: boolean; voice: string | null; model: string; cap: number; used: number };
  if (!g?.enabled) return { ok: false, reason: "off" };
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return { ok: false, reason: "not_configured" };
  if ((g.used ?? 0) >= (g.cap ?? 200)) return { ok: false, reason: "cap" };

  const { system, user } = buildBulkPrompt(g.voice, currentSubject, currentBody, situation);
  let json: unknown;
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15_000);
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: g.model, max_tokens: 600, system, messages: [{ role: "user", content: user }] }),
      signal: ctrl.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return { ok: false, reason: "model_error" };
    json = await res.json();
  } catch {
    return { ok: false, reason: "model_error" };
  }
  const { text, inputTokens, outputTokens } = parseApiResponse(json);
  const draft = parseDraft(text);
  if (!draft) return { ok: false, reason: "unreadable" };
  await supabase.rpc("record_ai_draft", {
    p_studio_id: studioId, p_member_id: null as unknown as string, p_situation: situation,
    p_model: g.model, p_input_tokens: inputTokens as unknown as number, p_output_tokens: outputTokens as unknown as number,
  });
  return { ok: true, subject: draft.subject, body: draft.body };
}
