"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type MoveResult =
  | { ok: true; warnings: string[] }
  | { ok: false; kind: "confirm"; bookedCount: number }
  | { ok: false; kind: "error"; message: string };

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
    booked_count?: number; warnings?: string[];
  };

  if (r.ok) {
    revalidatePath("/schedule");
    revalidatePath("/");
    return { ok: true, warnings: r.warnings ?? [] };
  }
  if (r.requires_confirmation) {
    return { ok: false, kind: "confirm", bookedCount: r.booked_count ?? 0 };
  }
  return {
    ok: false, kind: "error",
    message:
      r.reason === "room_busy" ? "That room is already in use at that time."
      : r.reason === "instructor_busy" ? "They are already teaching then."
      : "That move was refused.",
  };
}
