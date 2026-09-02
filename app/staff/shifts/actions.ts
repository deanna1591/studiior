"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type ShiftState = { ok: boolean; message: string } | null;

const refresh = () => {
  revalidatePath("/shifts");
  revalidatePath("/shifts/applications");
  revalidatePath("/schedule");
};

/**
 * An instructor asking for a shift.
 *
 * Decision 9 still holds: they are not assigning themselves. apply_for_shift()
 * creates a request; a manager decides. Applying outside their stated
 * availability is permitted and warned, never blocked.
 */
export async function applyForShift(_prev: ShiftState, fd: FormData): Promise<ShiftState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("apply_for_shift", {
    p_occurrence_id: String(fd.get("occurrence_id") ?? ""),
    p_note: String(fd.get("note") ?? "").trim() || undefined,
  });

  if (error) {
    return {
      ok: false,
      message:
        /PT403/.test(error.message) ? "Only instructors at this studio can apply."
        : /PT409/.test(error.message) ? "That shift is no longer open to you."
        : /PT402/.test(error.message) ? "This studio's subscription is not active."
        : error.message,
    };
  }

  refresh();
  const outside = (data as unknown as { outside_availability?: boolean })?.outside_availability;
  return {
    ok: true,
    message: outside
      ? "Asked for. That is outside the availability you gave us, so they will see that too."
      : "Asked for. The studio will let you know.",
  };
}

export async function approveApplication(_prev: ShiftState, fd: FormData): Promise<ShiftState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("approve_shift_application", {
    p_application_id: String(fd.get("application_id") ?? ""),
  });
  if (error) {
    return {
      ok: false,
      message:
        /PT403/.test(error.message) ? "Approving a shift is the owner's or a manager's to do."
        : /PT409/.test(error.message) ? "They are already teaching something at that time."
        : error.message,
    };
  }
  refresh();
  const n = (data as unknown as { auto_declined?: number })?.auto_declined ?? 0;
  return {
    ok: true,
    message: n > 0
      ? `Approved. ${n} other application${n === 1 ? " was" : "s were"} declined and told.`
      : "Approved, and they have been told.",
  };
}

export async function declineApplication(_prev: ShiftState, fd: FormData): Promise<ShiftState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { error } = await supabase.rpc("decline_shift_application", {
    p_application_id: String(fd.get("application_id") ?? ""),
  });
  if (error) {
    return /PT403/.test(error.message)
      ? { ok: false, message: "Declining a shift is the owner's or a manager's to do." }
      : { ok: false, message: error.message };
  }
  refresh();
  return { ok: true, message: "Declined, and they have been told." };
}

/**
 * An instructor pulling out of a class they agreed to teach.
 *
 * Deliberately available right up to the class: an instructor who cannot make
 * it and has no way to say so tells nobody, and the studio finds out at 6am.
 */
export async function withdrawFromShift(_prev: ShiftState, fd: FormData): Promise<ShiftState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("withdraw_from_shift", {
    p_occurrence_id: String(fd.get("occurrence_id") ?? ""),
  });
  if (error) {
    return /PT403/.test(error.message)
      ? { ok: false, message: "You are not teaching that class." }
      : { ok: false, message: error.message };
  }
  refresh();
  const n = (data as unknown as { booked_count?: number })?.booked_count ?? 0;
  return {
    ok: true,
    message: n > 0
      ? `Withdrawn. The studio has been told, and that ${n === 1 ? "member is" : n + " members are"} booked in.`
      : "Withdrawn, and the studio has been told.",
  };
}
