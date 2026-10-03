"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import type { Json } from "@/lib/database.types";

/**
 * Decision 50 — the campaign server actions.
 *
 * The real boundary is the database: every reader/writer is manager-up inside
 * (and the tables are manager-up RLS), so these are thin wrappers. Each
 * send/test/schedule SAVES the current editor values to the campaign first, so
 * the row the SQL reads is exactly what is on screen.
 */
export type CampaignResult = { ok: true; sentence?: string } | { error: string };
export type CountResult = { count: number } | { error: string };

export type AudienceFilter = {
  plan_state?: string | null;
  health?: string | null;
  joined_days?: number | null;
};

function cleanFilter(f: AudienceFilter): Json {
  const o: { [k: string]: Json } = {};
  if (f.plan_state) o.plan_state = f.plan_state;
  if (f.health) o.health = f.health;
  if (f.joined_days && f.joined_days > 0) o.joined_days = f.joined_days;
  return o;
}

const say = (m: string) =>
  /PT403/.test(m) ? "Campaigns are for owners and managers."
  : /PT404/.test(m) ? "That campaign no longer exists."
  : /PT4\d\d/.test(m) ? m.replace(/^.*?:\s*/, "").replace(/\s*\(.*$/, "")
  : m;

function revalidate(id?: string) {
  revalidatePath("/campaigns");
  if (id) revalidatePath(`/campaigns/${id}`, "page");
}

/** New blank draft, then straight into its editor. */
export async function createCampaign(): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const supabase = createClient();
  const { data, error } = await supabase
    .from("campaigns")
    .insert({ studio_id: ctx.studioId, created_by: ctx.userId, subject: "", body: "", audience: {} })
    .select("id")
    .single();
  if (error || !data) return;
  revalidate();
  redirect(`/campaigns/${data.id}`);
}

/** Save subject/body/audience onto a draft. */
export async function saveCampaign(
  id: string, subject: string, body: string, filter: AudienceFilter,
): Promise<CampaignResult> {
  const supabase = createClient();
  const { error } = await supabase
    .from("campaigns")
    .update({ subject, body, audience: cleanFilter(filter), updated_at: new Date().toISOString() })
    .eq("id", id)
    .eq("status", "draft");
  if (error) return { error: say(error.message) };
  revalidate(id);
  return { ok: true };
}

/** The opted-in count for a filter, live under the composer. */
export async function audienceCount(id: string, filter: AudienceFilter): Promise<CountResult> {
  const supabase = createClient();
  // Resolve the studio from the campaign (RLS lets a manager read only theirs).
  const { data: c } = await supabase.from("campaigns").select("studio_id").eq("id", id).single();
  if (!c) return { error: "That campaign no longer exists." };
  const { data, error } = await supabase.rpc("campaign_audience", {
    p_studio_id: c.studio_id, p_filter: cleanFilter(filter),
  });
  if (error) return { error: say(error.message) };
  return { count: (data ?? []).length };
}

async function persist(id: string, subject: string, body: string, filter: AudienceFilter) {
  const supabase = createClient();
  await supabase
    .from("campaigns")
    .update({ subject, body, audience: cleanFilter(filter), updated_at: new Date().toISOString() })
    .eq("id", id)
    .eq("status", "draft");
  return supabase;
}

export async function sendTest(
  id: string, subject: string, body: string, filter: AudienceFilter,
): Promise<CampaignResult> {
  const supabase = await persist(id, subject, body, filter);
  const { data, error } = await supabase.rpc("send_campaign_test", { p_campaign_id: id });
  if (error) return { error: say(error.message) };
  revalidate(id);
  return { ok: true, sentence: (data as { sentence?: string })?.sentence ?? "Test sent." };
}

export async function sendNow(
  id: string, subject: string, body: string, filter: AudienceFilter,
): Promise<CampaignResult> {
  const supabase = await persist(id, subject, body, filter);
  const { data, error } = await supabase.rpc("send_campaign", { p_campaign_id: id });
  if (error) return { error: say(error.message) };
  revalidate(id);
  return { ok: true, sentence: (data as { sentence?: string })?.sentence ?? "Sending." };
}

export async function scheduleCampaign(
  id: string, subject: string, body: string, filter: AudienceFilter, whenIso: string,
): Promise<CampaignResult> {
  const supabase = await persist(id, subject, body, filter);
  const { data, error } = await supabase.rpc("send_campaign", { p_campaign_id: id, p_when: whenIso });
  if (error) return { error: say(error.message) };
  revalidate(id);
  return { ok: true, sentence: (data as { sentence?: string })?.sentence ?? "Scheduled." };
}

export async function cancelCampaign(id: string): Promise<CampaignResult> {
  const supabase = createClient();
  const { error } = await supabase.rpc("cancel_campaign", { p_campaign_id: id });
  if (error) return { error: say(error.message) };
  revalidate(id);
  return { ok: true, sentence: "Campaign cancelled." };
}

/** Duplicate any campaign into a fresh draft, then open it. */
export async function duplicateCampaign(id: string): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const supabase = createClient();
  const { data: src } = await supabase
    .from("campaigns").select("subject, body, audience").eq("id", id).single();
  if (!src) return;
  const { data, error } = await supabase
    .from("campaigns")
    .insert({ studio_id: ctx.studioId, created_by: ctx.userId,
              subject: src.subject, body: src.body, audience: src.audience })
    .select("id").single();
  if (error || !data) return;
  revalidate();
  redirect(`/campaigns/${data.id}`);
}
