"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type CoverState = { ok: boolean; message: string } | null;

const refresh = () => {
  revalidatePath("/shifts");
  revalidatePath("/shifts/cover");
  revalidatePath("/shifts/applications");
  revalidatePath("/schedule");
  revalidatePath("/");
};

const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers can answer a cover request."
  : /PT404/.test(m) ? "That request no longer exists."
  : /PT409/.test(m) ? "Somebody has already answered this one."
  : /PT402/.test(m) ? "This studio's subscription is not active."
  : /PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

/** An instructor asking to be taken off a class. Staff always decide. */
export async function requestCover(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("request_cover", {
    p_occurrence_id: String(fd.get("occurrence_id") ?? ""),
    p_reason: String(fd.get("reason") ?? "").trim() || undefined,
  });
  if (error) return { ok: false, message: say(error.message) };

  const r = data as unknown as { already_open?: boolean; urgent?: boolean };
  refresh();
  if (r?.already_open) {
    return { ok: true, message: "You have already asked about this one. They can see it." };
  }
  return {
    ok: true,
    message: r?.urgent
      ? "Asked, and flagged as urgent because it is so close. Keep the class in your plans until they answer — you are still on it."
      : "Asked. You are still on the class until the studio arranges something.",
  };
}

export async function withdrawCover(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { error } = await supabase.rpc("withdraw_cover_request", {
    p_request_id: String(fd.get("request_id") ?? ""),
  });
  if (error) return { ok: false, message: say(error.message) };
  refresh();
  return { ok: true, message: "Taken back. You are teaching it as normal." };
}

/**
 * Staff answering. Two shapes, one call: name a replacement, or publish it as
 * an open shift and hand it to Decision 17's application flow.
 */
export async function approveCover(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const mode = String(fd.get("mode") ?? "");
  const who = String(fd.get("instructor_id") ?? "").trim();
  if (mode === "assign" && !who) {
    return { ok: false, message: "Pick who is covering it." };
  }

  const supabase = createClient();
  const { data, error } = await supabase.rpc("approve_cover_request", {
    p_request_id: String(fd.get("request_id") ?? ""),
    p_mode: mode,
    p_instructor_id: mode === "assign" ? who : undefined,
  });
  if (error) return { ok: false, message: say(error.message) };

  const r = data as unknown as {
    ok?: boolean; reason?: string; members_told?: number;
    free_cancellation_granted?: boolean;
    cover_notified?: boolean; cover_name?: string | null;
    blocked_by?: { name?: string; at?: string; room?: string };
  };

  // A refusal comes back as ok:false rather than as an error — the replacement
  // is already teaching, which the exclusion constraint will not bend for.
  if (r?.ok === false) {
    refresh();
    return {
      ok: false,
      message: r.reason === "instructor_busy"
        ? `They are already teaching ${r.blocked_by?.name ?? "another class"}${
            r.blocked_by?.at ? ` at ${r.blocked_by.at}` : ""}. Pick somebody else.`
        : r.reason === "room_busy"
          ? "That room is taken at the same time."
          : "That could not be arranged.",
    };
  }

  refresh();
  if (mode === "open") {
    return { ok: true, message: "Opened up. Instructors can apply for it now." };
  }
  const told = r?.members_told ?? 0;
  // An instructor with no login has no address anywhere in the schema, and that
  // is the ordinary case rather than an edge. Saying so beats a success message
  // that implies an email nobody sent.
  const reach = r?.cover_notified
    ? ""
    : ` ${r?.cover_name ?? "They"} has no login, so nothing was emailed to them — tell them yourself.`;
  return {
    ok: true,
    message:
      (told === 0
        ? "Covered. Nobody was booked, so no member has been emailed."
        : `Covered. ${told} booked member${told === 1 ? " has" : "s have"} been told${
            r?.free_cancellation_granted
              ? " — and because it is inside the cancellation window, they can cancel without it counting against them."
              : "."}`) + reach,
  };
}

export async function declineCover(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { error } = await supabase.rpc("decline_cover_request", {
    p_request_id: String(fd.get("request_id") ?? ""),
    p_reason: String(fd.get("reason") ?? "").trim() || undefined,
  });
  if (error) return { ok: false, message: say(error.message) };
  refresh();
  return {
    ok: true,
    message: "Declined, and they have been told they are still teaching it.",
  };
}
