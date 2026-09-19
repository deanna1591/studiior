"use server";

import { createClient } from "@/lib/supabase/server";

// Decision 33 Part B. The mint/revoke server actions behind the calendar-feed
// control, shared by the member settings screen and the instructor Me screen.
// Guarding is in the SQL (mint_calendar_feed / revoke_calendar_feed resolve the
// caller to their own member or instructor row); these only relay.
export type FeedKind = "member" | "instructor";

export async function mintFeed(studioId: string, kind: FeedKind): Promise<{ token?: string; error?: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("mint_calendar_feed", {
    p_studio_id: studioId, p_kind: kind,
  });
  if (error) return { error: error.message };
  return { token: data as string };
}

export async function revokeFeed(studioId: string, kind: FeedKind): Promise<{ ok?: boolean; error?: string }> {
  const supabase = createClient();
  const { error } = await supabase.rpc("revoke_calendar_feed", {
    p_studio_id: studioId, p_kind: kind,
  });
  if (error) return { error: error.message };
  return { ok: true };
}
