"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type ArchiveState =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | { ok: false; confirm: true; message: string; kind: string; id: string }
  | null;

type Kind = "class_type" | "room" | "instructor";

const pathFor = (kind: Kind) =>
  kind === "class_type" ? "/class-types" : kind === "room" ? "/rooms" : "/instructors";

const refresh = (kind: Kind) => {
  revalidatePath(pathFor(kind));
  revalidatePath("/schedule");
  revalidatePath("/shifts/applications");
  revalidatePath("/");
};

const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers can do that."
  : /PT404/.test(m) ? "That record no longer exists."
  : /PT409/.test(m) ? m.replace(/^.*?:\s*/, "")
  : /PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

/**
 * Archive, in two steps wherever it has consequences.
 *
 * The first press asks the database what will happen and shows the sentence it
 * returns; the second press carries a confirm flag. The studio never finds out
 * what archiving did by watching it happen — which for an instructor means
 * three classes quietly losing their teacher.
 */
export async function archiveRecord(_prev: ArchiveState, fd: FormData): Promise<ArchiveState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const kind = String(fd.get("kind") ?? "") as Kind;
  const id = String(fd.get("id") ?? "");
  const confirmed = String(fd.get("confirm") ?? "") === "1";

  const supabase = createClient();
  const { data, error } = await supabase.rpc("archive_record", {
    p_kind: kind, p_id: id, p_confirm: confirmed,
  });
  if (error) return { ok: false, message: say(error.message) };

  const r = data as unknown as {
    ok?: boolean; blocked?: boolean; reason?: string;
    requires_confirmation?: boolean; effect?: string;
    classes_opened?: number; series_stopped?: number;
  };

  // Blocked is final — a room with classes in it needs those classes moved,
  // and no amount of confirming changes that.
  if (r?.blocked) return { ok: false, message: r.reason ?? "That cannot be archived yet." };

  if (r?.requires_confirmation) {
    return { ok: false, confirm: true, kind, id,
             message: `${r.effect} Archive anyway?` };
  }

  refresh(kind);
  const opened = r?.classes_opened ?? 0;
  const stopped = r?.series_stopped ?? 0;
  return {
    ok: true,
    message: "Archived."
      + (opened ? ` ${opened} class${opened === 1 ? "" : "es"} ${opened === 1 ? "is" : "are"} now an open shift — every manager has been emailed.` : "")
      + (stopped ? ` ${stopped} recurring series stopped making new classes.` : ""),
  };
}

export async function restoreRecord(_prev: ArchiveState, fd: FormData): Promise<ArchiveState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const kind = String(fd.get("kind") ?? "") as Kind;

  const supabase = createClient();
  const { data, error } = await supabase.rpc("restore_record", {
    p_kind: kind, p_id: String(fd.get("id") ?? ""),
  });
  if (error) return { ok: false, message: say(error.message) };

  refresh(kind);
  const note = (data as unknown as { note?: string | null })?.note;
  return { ok: true, message: "Restored. Members can see it again." + (note ? ` ${note}` : "") };
}

/**
 * Delete, which the database refuses whenever anything points at the record.
 *
 * Worth knowing why the guard exists: every foreign key onto these three tables
 * is ON DELETE SET NULL, so before migration 058 this did not fail — it
 * succeeded and stripped the instructor's name off every class they had ever
 * taught, silently.
 */
export async function deleteRecord(_prev: ArchiveState, fd: FormData): Promise<ArchiveState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const kind = String(fd.get("kind") ?? "") as Kind;
  const table = kind === "class_type" ? "class_types" : kind === "room" ? "rooms" : "instructors";

  const supabase = createClient();
  const { data, error } = await supabase.from(table)
    .delete().eq("id", String(fd.get("id") ?? "")).select("id");

  if (error) {
    return {
      ok: false,
      message: /PT409/.test(error.message)
        // The guard's own sentence, which names what is in the way, plus its
        // hint. Better than anything this layer could compose.
        ? `${say(error.message)} Archive it instead — the record survives and stops being offered.`
        : say(error.message),
    };
  }
  // A refused DELETE does not raise: RLS makes the row invisible and PostgREST
  // returns 200 with an empty array.
  if (!data || data.length === 0) {
    return { ok: false, message: "Nothing was deleted — only owners and managers can delete." };
  }

  refresh(kind);
  return { ok: true, message: "Deleted." };
}
