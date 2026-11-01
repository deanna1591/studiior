"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const MIME = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
const MAX = 1048576;

export type ReplyState = { ok?: true; error?: string } | null;

/**
 * Decision 89 — a studio reply. Runs with the staff user's cookie session, so
 * the storage upload and the RPC pass the staff member's RLS (no service-role
 * key). Size and type checked here and again in the RPC.
 */
export async function sendStaffReply(_prev: ReplyState, formData: FormData): Promise<ReplyState> {
  const supabase = createClient();
  const studioId = String(formData.get("studio_id") ?? "");
  const threadId = String(formData.get("thread_id") ?? "");
  const body = String(formData.get("body") ?? "").trim();
  if (!body) return { error: "Write a message before sending." };
  if (body.length > 2000) return { error: "Keep your message to 2000 characters or fewer." };

  let path: string | null = null;
  let name: string | null = null;
  let bytes: number | null = null;
  let mime: string | null = null;

  const file = formData.get("attachment");
  if (file instanceof File && file.size > 0) {
    if (file.size > MAX) return { error: "That file is over 1 MB. Try a smaller photo or PDF." };
    if (!MIME.includes(file.type)) return { error: "Photos and PDFs only." };
    const safe = (file.name || "attachment").replace(/[^a-zA-Z0-9._-]/g, "_").slice(-60);
    path = `${studioId}/${threadId}/${Date.now()}-${safe}`;
    const up = await supabase.storage.from("message-attachments")
      .upload(path, file, { contentType: file.type, upsert: false });
    if (up.error) return { error: "Could not attach that file. Try again." };
    name = file.name || safe;
    bytes = file.size;
    mime = file.type;
  }

  const { data, error } = await supabase.rpc("staff_send_message", {
    p_thread_id: threadId,
    p_body: body,
    p_attachment_path: path ?? undefined,
    p_attachment_name: name ?? undefined,
    p_attachment_bytes: bytes ?? undefined,
    p_attachment_mime: mime ?? undefined,
  });
  if (error) return { error: "Could not send. Try again." };
  const res = data as { ok?: boolean; reason?: string } | null;
  if (!res?.ok) return { error: res?.reason ?? "Could not send." };

  revalidatePath(`/messages/${threadId}`);
  revalidatePath("/messages");
  return { ok: true };
}
