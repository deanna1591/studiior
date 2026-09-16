"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { computeAssignCandidates, type AssignCandidate } from "@/lib/assign";

/**
 * Who could take an unstaffed class — loaded on demand when the calendar's
 * Assign popover opens, so an assigned class (the common case) pays for none of
 * it and the whole week's candidates are not computed up front. Same helper as
 * the roster's Assign panel.
 */
export async function assignCandidates(
  occurrenceId: string,
): Promise<{ candidates: AssignCandidate[]; pendingApplications: number } | { error: string }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };

  const supabase = createClient();
  const [{ data: occ }, { count }] = await Promise.all([
    supabase.from("class_occurrences")
      .select("id, class_type_id, starts_at, ends_at, status, instructor_id")
      .eq("id", occurrenceId).maybeSingle(),
    supabase.from("shift_applications")
      .select("id", { count: "exact", head: true })
      .eq("occurrence_id", occurrenceId).eq("status", "pending"),
  ]);
  if (!occ) return { error: "That class no longer exists." };
  // A still-scheduled class has candidates — to fill it when unstaffed, or to
  // swap the instructor when it is assigned. A cancelled class has none.
  if (occ.status !== "scheduled") {
    return { candidates: [], pendingApplications: count ?? 0 };
  }
  const candidates = await computeAssignCandidates(supabase, occ, ctx.timeZone);
  return { candidates, pendingApplications: count ?? 0 };
}

export type BlockedBy = {
  occurrenceId: string; name: string; at: string;
  who: string | null; room: string | null;
};

export type MoveResult =
  | { ok: true; warnings: string[]; significant: boolean }
  | { ok: false; kind: "confirm"; bookedCount: number }
  | { ok: false; kind: "error"; message: string; blockedBy?: BlockedBy | null };

/**
 * The only thing the calendar is allowed to do.
 *
 * Every drag and every resize comes through move_occurrence(), which is also
 * what the edit form calls — so a rule added there cannot be enforced on one
 * and forgotten on the other. The calendar checks nothing itself; it draws the
 * answer.
 *
 * Two steps when members are booked: the first call refuses and says how many
 * people are affected, the UI asks, and the second call moves it and emails
 * them. A drag that silently mails forty people because somebody's finger
 * slipped is worse than one that stops to ask.
 */
export async function moveClass(input: {
  occurrenceId: string;
  startsAt?: string;
  endsAt?: string;
  instructorId?: string | null;
  confirm?: boolean;
}): Promise<MoveResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, kind: "error", message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("move_occurrence", {
    p_occurrence_id: input.occurrenceId,
    p_starts_at: input.startsAt,
    p_ends_at: input.endsAt,
    // null means "make it an open shift", undefined means "leave it alone" —
    // one nullable argument cannot say both, so the function takes a flag.
    p_instructor_id: input.instructorId ?? undefined,
    p_clear_instructor: input.instructorId === null,
    p_confirm: input.confirm ?? false,
  });

  if (error) {
    const m = error.message;
    return {
      ok: false, kind: "error",
      message:
        /PT403/.test(m) ? "Only owners and managers change the timetable."
        : /PT402/.test(m) ? "This studio's subscription is not active."
        : /PT409/.test(m) ? "That class cannot be moved."
        : m,
    };
  }

  const r = data as unknown as {
    ok: boolean; requires_confirmation?: boolean; reason?: string;
    booked_count?: number; warnings?: string[]; significant?: boolean;
    blocked_by?: {
      occurrence_id: string; name: string; at: string;
      who: string | null; room: string | null;
    } | null;
  };

  if (r.ok) {
    revalidatePath("/schedule");
    revalidatePath("/");
    return { ok: true, warnings: r.warnings ?? [], significant: r.significant ?? false };
  }
  if (r.requires_confirmation) {
    return { ok: false, kind: "confirm", bookedCount: r.booked_count ?? 0 };
  }
  return {
    ok: false, kind: "error",
    // The sentence stops short so the screen can finish it with a link to
    // whatever is in the way.
    message:
      r.reason === "room_busy" ? "That room is taken —"
      : r.reason === "instructor_busy" ? "They are already teaching —"
      : "That move was refused.",
    blockedBy: r.blocked_by
      ? { occurrenceId: r.blocked_by.occurrence_id, name: r.blocked_by.name,
          at: r.blocked_by.at, who: r.blocked_by.who, room: r.blocked_by.room }
      : null,
  };
}
