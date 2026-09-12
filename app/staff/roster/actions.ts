"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type OpenShiftState =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | null;

/**
 * Take an instructor off a class and publish it as an open shift.
 *
 * open_shift() clears the instructor, keeps the class bookable, tells the
 * instructor removed (or reports they have no login), and audits it. The
 * class stays exactly where it is on the calendar; only its staffing changes.
 */
export async function openShift(_prev: OpenShiftState, fd: FormData): Promise<OpenShiftState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const reason = String(fd.get("reason") ?? "").trim();
  if (!reason) return { ok: false, message: "Say why — the instructor gets this, and it goes on the record." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("open_shift", {
    p_occurrence_id: occurrenceId, p_reason: reason,
  });
  if (error) return { ok: false, message: error.message };

  const r = data as unknown as {
    ok: boolean; reason?: string; removed_instructor: string;
    removed_notified: boolean; removed_uncontactable: boolean;
  };
  if (!r.ok) return { ok: false, message: r.reason ?? "That could not be done." };

  revalidatePath(`/roster/${occurrenceId}`);
  revalidatePath("/schedule");
  const tail = r.removed_uncontactable
    ? ` ${r.removed_instructor} has no login, so tell them yourself.`
    : ` ${r.removed_instructor} has been told.`;
  return { ok: true, message: `Opened as a shift.${tail} Qualified instructors are emailed shortly.` };
}
