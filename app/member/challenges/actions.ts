"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getMemberContext } from "@/lib/auth";
import type { ActionResult } from "../actions";

/**
 * Join a challenge. join_challenge() enforces the deadline (Decision 6) and
 * backfills every qualifying class since the start (§9.2), so the member's
 * progress is right the instant they join — a raw insert into
 * challenge_participants cannot do either and RLS no longer lets a member try.
 */
export async function joinChallenge(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const supabase = createClient();

  const id = String(fd.get("challenge_id") ?? "");
  const { error } = await supabase.rpc("join_challenge", { p_challenge_id: id });
  if (error) {
    if (error.code === "PT409" && error.message.includes("deadline")) {
      return { ok: false, message: "The deadline to join this one has passed." };
    }
    return { ok: false, message: error.message };
  }

  for (const p of ["/", "/challenges", `/challenges/${id}`]) revalidatePath(p);
  return { ok: true, message: "You're in — every class from the start counts." };
}
