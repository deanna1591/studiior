"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type RecordState = { ok: boolean; message: string } | null;

/** The enum the column actually is, so a typo cannot reach the database. */
const CATEGORIES = ["general", "injury", "medical", "preference", "admin"] as const;
type Category = (typeof CATEGORIES)[number];
const asCategory = (v: string): Category =>
  (CATEGORIES as readonly string[]).includes(v) ? (v as Category) : "general";

const refresh = (memberId: string) => {
  revalidatePath(`/members/${memberId}`);
  revalidatePath("/members");
};

const say = (m: string) =>
  /PT403/.test(m) ? "You do not have permission for that."
  : /PT404/.test(m) ? "That record no longer exists."
  : /PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : /row-level security|Unauthorized/i.test(m) ? "That was refused."
  : m;

// ---------------------------------------------------------------- notes -----
export async function saveNote(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const body = String(fd.get("body") ?? "").trim();
  if (!body) return { ok: false, message: "A note needs something in it." };

  const row = {
    studio_id: ctx.studioId,
    member_id: memberId,
    author_user_id: ctx.userId,
    category: asCategory(String(fd.get("category") ?? "general")),
    body,
    pinned: fd.get("pinned") === "on",
    managers_only: fd.get("managers_only") === "on",
  };

  const supabase = createClient();
  const id = String(fd.get("note_id") ?? "");
  // A refused write does not raise — RLS makes the row invisible and PostgREST
  // answers 200 with an empty array, so both branches check what came back.
  const { data, error } = id
    ? await supabase.from("member_notes").update(row).eq("id", id).select("id")
    : await supabase.from("member_notes").insert(row).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) return { ok: false, message: "That note was not saved." };

  refresh(memberId);
  return { ok: true, message: id ? "Note updated." : "Note added." };
}

/**
 * Resolve rather than delete.
 *
 * An injury note that never resolves is worse than none: it either stays on the
 * roster forever and stops being read, or somebody deletes it and the studio
 * loses that the shoulder was ever a problem. Resolving keeps the record and
 * takes it off the pinned list.
 */
export async function resolveNote(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const reopen = fd.get("reopen") === "1";

  const supabase = createClient();
  const { data, error } = await supabase.from("member_notes")
    .update({ active: reopen, pinned: reopen ? false : false })
    .eq("id", String(fd.get("note_id") ?? "")).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) return { ok: false, message: "That note was not changed." };

  refresh(memberId);
  return { ok: true, message: reopen ? "Reopened." : "Resolved. It stays on the record and comes off the roster." };
}

export async function deleteNote(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const supabase = createClient();
  const { data, error } = await supabase.from("member_notes")
    .delete().eq("id", String(fd.get("note_id") ?? "")).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) return { ok: false, message: "That note was not deleted." };
  refresh(memberId);
  return { ok: true, message: "Deleted." };
}

// ---------------------------------------------------------------- goals -----
export async function saveGoal(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const title = String(fd.get("title") ?? "").trim();
  if (!title) return { ok: false, message: "A goal needs a name." };

  const targetType = String(fd.get("target_type") ?? "class_count");
  const rawValue = String(fd.get("target_value") ?? "").trim();
  const row = {
    studio_id: ctx.studioId,
    member_id: memberId,
    title,
    target_type: targetType,
    target_value: rawValue ? Number(rawValue) : null,
    target_date: String(fd.get("target_date") ?? "") || null,
  };
  if (targetType === "class_count" && !row.target_value) {
    return { ok: false, message: "How many classes? A count goal needs a number to measure against." };
  }

  const supabase = createClient();
  const id = String(fd.get("goal_id") ?? "");
  const { data, error } = id
    ? await supabase.from("member_goals").update(row).eq("id", id).select("id")
    : await supabase.from("member_goals").insert(row).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) return { ok: false, message: "That goal was not saved." };

  refresh(memberId);
  return { ok: true, message: id ? "Goal updated." : "Goal set. Progress counts from today." };
}

export async function completeGoal(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const done = fd.get("reopen") !== "1";

  const supabase = createClient();
  const { data, error } = await supabase.from("member_goals")
    .update({ status: done ? "completed" : "active", completed_at: done ? new Date().toISOString() : null })
    .eq("id", String(fd.get("goal_id") ?? "")).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) return { ok: false, message: "That goal was not changed." };
  refresh(memberId);
  return { ok: true, message: done ? "Marked done." : "Reopened." };
}

export async function deleteGoal(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const supabase = createClient();
  const { data, error } = await supabase.from("member_goals")
    .delete().eq("id", String(fd.get("goal_id") ?? "")).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) return { ok: false, message: "That goal was not deleted." };
  refresh(memberId);
  return { ok: true, message: "Deleted." };
}

// ------------------------------------------------------- photo + documents --
/**
 * A photo uploaded by the desk, for the walk-in who will not do it themselves.
 *
 * Same private bucket and same path shape as the member's own upload — the
 * storage policy keys on the member id in the first path segment, and migration
 * 059 adds the staff half of it. `members.avatar_url` holds the object PATH,
 * never a URL: a signed URL expires and a column full of dead links is worse
 * than a column full of paths.
 */
export async function uploadMemberPhoto(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const file = fd.get("photo") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  if (file.size > 2_000_000) return { ok: false, message: "That photo is over 2 MB, which is the bucket's own ceiling." };
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    return { ok: false, message: "JPEG, PNG or WebP." };
  }

  const supabase = createClient();
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "jpg";
  const path = `${memberId}/avatar-${Date.now()}.${ext}`;
  const up = await supabase.storage.from("member-avatars").upload(path, file, { upsert: false });
  if (up.error) return { ok: false, message: say(up.error.message) };

  const { data, error } = await supabase.from("members")
    .update({ avatar_url: path }).eq("id", memberId).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) return { ok: false, message: "The photo uploaded but the member was not updated." };

  refresh(memberId);
  return { ok: true, message: "Photo saved." };
}

/**
 * Filing a document, and the waiver's side effect.
 *
 * record_document() is what sets members.waiver_signed_at — §2.1's booking gate
 * has been a timestamp somebody ticked, with no document behind it, since
 * migration 002.
 */
export async function uploadDocument(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const kind = String(fd.get("kind") ?? "other");
  const file = fd.get("document") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a file first." };
  if (file.size > 10_000_000) return { ok: false, message: "That file is over 10 MB, which is the bucket's own ceiling." };

  const supabase = createClient();
  const safe = file.name.replace(/[^a-zA-Z0-9._-]/g, "-").slice(-80);
  // studio / member / file — the first segment is the tenant boundary the
  // storage policy checks, the second is the person.
  const path = `${ctx.studioId}/${memberId}/${Date.now()}-${safe}`;
  const up = await supabase.storage.from("member-documents").upload(path, file, { upsert: false });
  if (up.error) return { ok: false, message: say(up.error.message) };

  const { data, error } = await supabase.rpc("record_document", {
    p_member_id: memberId, p_kind: kind, p_filename: file.name,
    p_storage_path: path, p_mime: file.type || undefined,
    p_size: file.size, p_note: String(fd.get("note") ?? "").trim() || undefined,
  });
  if (error) {
    // The row failed, so the object is orphaned. Cleared rather than left in a
    // private bucket nothing points at.
    await supabase.storage.from("member-documents").remove([path]);
    return { ok: false, message: say(error.message) };
  }

  refresh(memberId);
  const signed = (data as unknown as { waiver_signed?: boolean })?.waiver_signed;
  return {
    ok: true,
    message: "Filed."
      + (signed ? " The waiver is now signed on their record, so they can book." : ""),
  };
}

export async function deleteDocument(_prev: RecordState, fd: FormData): Promise<RecordState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const path = String(fd.get("path") ?? "");

  const supabase = createClient();
  const { data, error } = await supabase.from("member_documents")
    .delete().eq("id", String(fd.get("document_id") ?? "")).select("id");
  if (error) return { ok: false, message: say(error.message) };
  if (!data?.length) {
    return { ok: false, message: "That was not deleted — only managers and owners can remove a document." };
  }
  // Deliberately after the row, and not fatal if it fails: an orphaned object
  // in a private bucket is recoverable; a row pointing at a file that is gone
  // is a download button that 404s.
  if (path) await supabase.storage.from("member-documents").remove([path]);

  refresh(memberId);
  return { ok: true, message: "Removed." };
}

/** A short-lived signed URL, asked for only when somebody presses download. */
export async function documentUrl(path: string): Promise<string | null> {
  const ctx = await getStaffContext();
  if (!ctx) return null;
  const supabase = createClient();
  const { data } = await supabase.storage.from("member-documents").createSignedUrl(path, 60);
  return data?.signedUrl ?? null;
}
