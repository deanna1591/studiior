"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

/** One line of the engine's working, exactly as it returns it. */
export type FillLine = {
  occurrence_id: string;
  class: string;
  when: string;
  outcome: "assigned" | "left_open";
  instructor?: string;
  why: string;
  deficit?: number;
  booked?: number;
};

export type FillRun = {
  ok: true;
  dry_run: boolean;
  from: string;
  to: string;
  assigned: number;
  left_open: number;
  commitment_fallback: boolean;
  no_commitment_for: string[];
  detail: FillLine[];
};

export type FillState =
  | { ok: false; message: string }
  | { ok: true; run: FillRun }
  | null;

const range = (fd: FormData) => ({
  from: String(fd.get("from") ?? "").trim() || null,
  to: String(fd.get("to") ?? "").trim() || null,
});

const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers can fill the timetable."
  : /PT404/.test(m) ? "That studio no longer exists."
  : /PT402/.test(m) ? "This studio's subscription is not active."
  : m;

async function run(fd: FormData, dry: boolean): Promise<FillState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const { from, to } = range(fd);
  if (!from || !to) return { ok: false, message: "Pick a start and an end date." };
  if (to < from) return { ok: false, message: "The end date is before the start date." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("assign_instructors", {
    p_studio_id: ctx.studioId, p_from: from, p_to: to, p_dry_run: dry,
  });
  if (error) return { ok: false, message: say(error.message) };

  if (!dry) {
    revalidatePath("/schedule");
    revalidatePath("/shifts/applications");
    revalidatePath("/");
  }
  return { ok: true, run: data as unknown as FillRun };
}

/** Nothing is written. Same call, `p_dry_run` true. */
export async function previewFill(_prev: FillState, fd: FormData) {
  return run(fd, true);
}

/**
 * The second, deliberate action.
 *
 * It RE-RUNS rather than replaying the preview. Between the two presses
 * somebody may have taken a shift, changed their availability or been
 * archived — applying a stale plan would assign a class to a person who is no
 * longer a candidate, which is exactly the silent wrong assignment the engine
 * refuses to make on its own. The result shown afterwards is what actually
 * happened, not what was predicted.
 */
export async function applyFill(_prev: FillState, fd: FormData) {
  return run(fd, false);
}
