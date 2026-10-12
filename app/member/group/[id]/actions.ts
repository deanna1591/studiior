"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type GroupActionState = { ok: boolean; error?: string } | null;

// book_group / cancel_group / swap_group_guest return a soft { ok, reason }
// (not a raise) for member-facing refusals. Turn each reason into a sentence,
// using the email the RPC names where it names one.
function bookReason(r: string | undefined, email?: string | null): string {
  switch (r) {
    case "already_booked": return `${email ?? "Someone"} is already booked on that class — pick a different person or class.`;
    case "class_full": return "That class doesn't have enough free seats for the whole group any more.";
    case "class_type_not_allowed": return "This package can't be used for that class.";
    case "host_already_booked": return "You already have a booking on that class.";
    case "duplicate_email": return `${email ?? "An email"} is listed twice — each guest needs a different email.`;
    case "email_is_host": return "One of the emails is your own — you are already seat one.";
    case "wrong_email_count": return "Please fill in every guest's email.";
    case "blank_email": return "One of the emails is blank.";
    case "window_closed": return "The window to book this group has closed.";
    case "not_bookable": return "That class can't be booked.";
    case "month_not_published": return "That class isn't open for booking yet.";
    case "not_staffed_yet": return "That class doesn't have an instructor yet.";
    case "not_authorised": return "Only the person who bought this group can book it.";
    case "already_booked_status": case "already_booked_group": return "This group is already booked.";
    default: return r ? `Couldn't book the group (${r}).` : "Couldn't book the group.";
  }
}

export async function bookGroupAction(_prev: GroupActionState, fd: FormData): Promise<GroupActionState> {
  const groupId = String(fd.get("group_id") ?? "");
  const occId = String(fd.get("occurrence_id") ?? "");
  const emails = fd.getAll("email").map(String).map((e) => e.trim()).filter(Boolean);
  const supabase = createClient();
  const { data, error } = await supabase.rpc("book_group", {
    p_group_purchase_id: groupId, p_occurrence_id: occId, p_emails: emails,
  });
  if (error) return { ok: false, error: error.message };
  const res = data as { ok?: boolean; reason?: string; email?: string | null; already_status?: string } | null;
  if (res?.ok) return { ok: true };
  // "already_<status>" is returned when the group is no longer unbooked.
  const reason = res?.reason?.startsWith("already_") ? "already_booked_group" : res?.reason;
  return { ok: false, error: bookReason(reason, res?.email) };
}

export async function swapGuestAction(_prev: GroupActionState, fd: FormData): Promise<GroupActionState> {
  const groupId = String(fd.get("group_id") ?? "");
  const oldEmail = String(fd.get("old_email") ?? "");
  const newEmail = String(fd.get("new_email") ?? "").trim();
  const supabase = createClient();
  const { data, error } = await supabase.rpc("swap_group_guest", {
    p_group_purchase_id: groupId, p_old_email: oldEmail, p_new_email: newEmail,
  });
  if (error) return { ok: false, error: error.message };
  const res = data as { ok?: boolean; reason?: string; email?: string | null } | null;
  if (res?.ok) { revalidatePath(`/group/${groupId}`); return { ok: true }; }
  if (res?.reason === "too_late") return { ok: false, error: "It's too close to the class to swap now." };
  return { ok: false, error: bookReason(res?.reason, res?.email) };
}

export async function cancelGroupAction(_prev: GroupActionState, fd: FormData): Promise<GroupActionState> {
  const groupId = String(fd.get("group_id") ?? "");
  const supabase = createClient();
  const { data, error } = await supabase.rpc("cancel_group", { p_group_purchase_id: groupId });
  if (error) {
    if (error.code === "PT403") return { ok: false, error: "Only the person who bought this group can cancel it." };
    if (error.code === "PT409") return { ok: false, error: "This group can't be cancelled." };
    return { ok: false, error: error.message };
  }
  const res = data as { ok?: boolean; late?: boolean } | null;
  revalidatePath(`/group/${groupId}`);
  return { ok: true, error: res?.late ? "late" : undefined };
}
