"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { computeAssignCandidates, type AssignCandidate } from "@/lib/assign";

/**
 * The occurrence's authoritative current staffing, read fresh when the panel
 * opens — so the panel's header ("who is teaching it") and its dropdown
 * ("(current)") are driven by the SAME fetched row, not by the click-time
 * CalEvent snapshot which can lag the database (e.g. a class assigned since the
 * week was last rendered). They disagreed before: "Nobody is teaching it" over a
 * dropdown reading "Coach Illiana (current)".
 */
export type CurrentStaffing = {
  instructorId: string | null;
  instructorName: string | null;
  staffing: "assigned" | "open" | "pending_approval";
  bookedCount: number;
  capacity: number;
  waitlistCount: number;
};

/**
 * Who could take an unstaffed class — loaded on demand when the calendar's
 * Assign popover opens, so an assigned class (the common case) pays for none of
 * it and the whole week's candidates are not computed up front. Same helper as
 * the roster's Assign panel. Also returns the occurrence's current staffing, so
 * the panel header and the dropdown agree (and refresh together).
 */
export async function assignCandidates(
  occurrenceId: string,
): Promise<{ candidates: AssignCandidate[]; pendingApplications: number; current: CurrentStaffing; requiresAvailability: boolean } | { error: string }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };

  const supabase = createClient();
  const [{ data: occ }, { count }, { data: scfg }] = await Promise.all([
    supabase.from("class_occurrences")
      .select("id, class_type_id, starts_at, ends_at, status, instructor_id, staffing, booked_count, capacity, waitlist_count")
      .eq("id", occurrenceId).maybeSingle(),
    supabase.from("shift_applications")
      .select("id", { count: "exact", head: true })
      .eq("occurrence_id", occurrenceId).eq("status", "pending"),
    // Decision 46: label a not-available entry "(not available)" under the switch.
    supabase.from("studio_settings").select("assign_requires_availability")
      .eq("studio_id", ctx.studioId).maybeSingle(),
  ]);
  const requiresAvailability = scfg?.assign_requires_availability ?? false;
  if (!occ) return { error: "That class no longer exists." };
  // Resolve the current instructor's name from the same read, so the header can
  // name whoever is on it without trusting the (possibly stale) click snapshot.
  let instructorName: string | null = null;
  if (occ.instructor_id) {
    const { data: ins } = await supabase.from("instructors")
      .select("display_name").eq("id", occ.instructor_id).maybeSingle();
    instructorName = ins?.display_name ?? null;
  }
  const current: CurrentStaffing = {
    instructorId: occ.instructor_id ?? null,
    instructorName,
    staffing: (occ.staffing ?? "open") as CurrentStaffing["staffing"],
    bookedCount: occ.booked_count ?? 0,
    capacity: occ.capacity ?? 0,
    waitlistCount: occ.waitlist_count ?? 0,
  };
  // A still-scheduled class has candidates — to fill it when unstaffed, or to
  // swap the instructor when it is assigned. A cancelled class has none.
  if (occ.status !== "scheduled") {
    return { candidates: [], pendingApplications: count ?? 0, current, requiresAvailability };
  }
  const candidates = await computeAssignCandidates(supabase, occ, ctx.timeZone);
  return { candidates, pendingApplications: count ?? 0, current, requiresAvailability };
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

export type PeriodAssignResult =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | null;

/**
 * Decision 42a — assign (or unassign) an instructor from the Schedule, for a
 * scope: just this class, every week this month, or until a date. Each
 * occurrence goes through the existing single-occurrence path, so Decision 38's
 * confirmation request, the double-booking constraints and the audit all apply;
 * a clash is skipped and named, never silently reassigned. The series template
 * is never touched. Instructor id empty = unassign (back to an open shift).
 */
export async function assignOccurrencesForPeriod(_prev: PeriodAssignResult, fd: FormData): Promise<PeriodAssignResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const instructorId = String(fd.get("instructor_id") ?? "");   // "" => unassign
  const scope = String(fd.get("scope") ?? "one");
  const untilRaw = String(fd.get("until") ?? "").trim();
  const confirmed = String(fd.get("confirmed") ?? "") === "on";
  if (scope === "until" && !untilRaw) return { ok: false, message: "Pick a date to assign until." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("assign_occurrences_for_period", {
    p_occurrence_id: occurrenceId,
    // Omitted (undefined) means the function's default null — i.e. unassign.
    p_instructor_id: instructorId || undefined,
    p_scope: scope,
    p_until: scope === "until" ? untilRaw : undefined,
    p_confirmed: confirmed,
  });
  if (error) {
    const m = error.message;
    return {
      ok: false,
      message: /PT403/.test(m) ? "Only owners and managers change the timetable."
        : /PT422/.test(m) ? "Check the scope and date."
        : m,
    };
  }

  const r = data as unknown as {
    ok: boolean; assigned: number; instructor: string | null;
    skipped: { occurrence_id: string; when: string; reason: string }[];
    warnings: string[];
  };
  const unassign = !instructorId;
  const n = r.assigned ?? 0;
  const who = r.instructor ?? "the instructor";
  const parts: string[] = [];
  parts.push(unassign
    ? `Unassigned ${n} ${n === 1 ? "class" : "classes"}.`
    : `Assigned ${who} to ${n} ${n === 1 ? "class" : "classes"}.`);
  const skipped = r.skipped ?? [];
  if (skipped.length > 0) {
    parts.push(`Skipped ${skipped.length}: ` + skipped.map((s) => `${s.when} — ${s.reason}`).join("; ") + ".");
  }
  if ((r.warnings ?? []).includes("outside_availability")) {
    parts.push(`${who} is outside the hours they gave us for at least one of these — assigned anyway.`);
  }

  revalidatePath("/schedule");
  revalidatePath("/");
  return { ok: true, message: parts.join(" ") };
}

export type PeriodCancelResult =
  | { ok: true; message: string }
  | { ok: false; message: string }
  | null;

/**
 * Decision 47 — staff cancel one class, or the rest of its studio-local weekday
 * this month, from the Schedule. Goes through cancel_occurrence per target, so
 * booked members get the Business Rules §3.2 treatment and the instructor, if
 * any, is told. Cause is one of no_instructor / studio_fault / force_majeure;
 * no_instructor on a class that has an instructor is refused (PT422).
 */
export async function cancelOccurrencesForPeriod(_prev: PeriodCancelResult, fd: FormData): Promise<PeriodCancelResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  const scope = String(fd.get("scope") ?? "one");
  const cause = String(fd.get("cause") ?? "");
  const reason = String(fd.get("reason") ?? "").trim();
  if (!["no_instructor", "studio_fault", "force_majeure"].includes(cause)) {
    return { ok: false, message: "Choose a reason for the cancellation." };
  }

  const supabase = createClient();
  const { data, error } = await supabase.rpc("cancel_occurrences_for_period", {
    p_occurrence_id: occurrenceId,
    p_scope: scope,
    p_cause: cause as "no_instructor" | "studio_fault" | "force_majeure",
    p_reason: reason || undefined,
  });
  if (error) {
    const m = error.message;
    return {
      ok: false,
      message: /PT403/.test(m) ? "Only owners and managers cancel a class."
        : /no instructor/i.test(m) ? "This class has an instructor — choose a different reason."
        : /PT422/.test(m) ? "Check the reason and scope."
        : m,
    };
  }

  const r = data as unknown as {
    ok: boolean; cancelled: number; members_affected: number;
    skipped: { occurrence_id: string; when: string; reason: string }[];
  };
  const n = r.cancelled ?? 0;
  const mcount = r.members_affected ?? 0;
  const parts: string[] = [`Cancelled ${n} ${n === 1 ? "class" : "classes"}.`];
  if (mcount > 0) parts.push(`${mcount} ${mcount === 1 ? "member" : "members"} told.`);
  const skipped = r.skipped ?? [];
  if (skipped.length > 0) {
    parts.push(`Skipped ${skipped.length}: ` + skipped.map((s) => `${s.when} — ${s.reason}`).join("; ") + ".");
  }

  revalidatePath("/schedule");
  revalidatePath("/");
  return { ok: true, message: parts.join(" ") };
}
