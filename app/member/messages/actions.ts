"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const MIME = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
const MAX = 1048576; // 1 MB — the same ceiling the RPC and the bucket enforce.

type State = { ok?: true; error?: string } | null;

/**
 * Decision 89 — a member sends a message. The server action runs with the
 * member's own cookie session, so the storage upload and the RPC both pass the
 * member's RLS (there is no service-role key). Size and type are checked here
 * before the upload AND again in the RPC. The attachment, if any, is uploaded
 * under {studio_id}/{thread_id}/ — the path the member's storage policy allows —
 * then its path is handed to member_send_message.
 */
export async function sendMemberMessage(_prev: State, formData: FormData): Promise<State> {
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

  const { data, error } = await supabase.rpc("member_send_message", {
    p_studio_id: studioId,
    p_body: body,
    p_attachment_path: path ?? undefined,
    p_attachment_name: name ?? undefined,
    p_attachment_bytes: bytes ?? undefined,
    p_attachment_mime: mime ?? undefined,
  });
  if (error) return { error: "Could not send your message. Try again." };
  const res = data as { ok?: boolean; reason?: string } | null;
  if (!res?.ok) return { error: res?.reason ?? "Could not send your message." };

  revalidatePath("/messages");
  return { ok: true };
}
