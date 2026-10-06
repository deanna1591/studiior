"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type TeamState = { ok: boolean; message: string } | null;

const say = (m: string) =>
  /PT403/.test(m) ? "You are not allowed to do that."
  : /PT409/.test(m) ? m.replace(/^.*?:\s*/, "")
  : /PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : /PT404/.test(m) ? "That person is no longer on the team."
  : m;

export async function inviteStaff(_prev: TeamState, fd: FormData): Promise<TeamState> {
  const email = String(fd.get("email") ?? "").trim();
  const role = String(fd.get("role") ?? "");
  const name = String(fd.get("name") ?? "").trim();
  if (!email) return { ok: false, message: "Enter an email address." };
  if (role !== "manager" && role !== "front_desk") return { ok: false, message: "Pick a role." };

  const { error } = await createClient().rpc("invite_staff", {
    p_email: email, p_role: role, p_name: name || undefined,
  });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/settings/team");
  return { ok: true, message: `Invited ${email}. They'll get an email to set a password.` };
}

export async function setStaffRole(_prev: TeamState, fd: FormData): Promise<TeamState> {
  const staffId = String(fd.get("staff_id") ?? "");
  const role = String(fd.get("role") ?? "") as "owner" | "manager" | "front_desk";
  const { error } = await createClient().rpc("set_staff_role", { p_staff_id: staffId, p_role: role });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/settings/team");
  return { ok: true, message: "Role changed." };
}

export async function removeStaff(_prev: TeamState, fd: FormData): Promise<TeamState> {
  const staffId = String(fd.get("staff_id") ?? "");
  const { error } = await createClient().rpc("remove_staff", { p_staff_id: staffId });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/settings/team");
  return { ok: true, message: "Access removed." };
}

// One dispatcher so a single useFormState in the client serves both per-row forms.
export async function rowDispatch(prev: TeamState, fd: FormData): Promise<TeamState> {
  return String(fd.get("op")) === "remove" ? removeStaff(prev, fd) : setStaffRole(prev, fd);
}
