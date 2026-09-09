"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type TypeState = { ok: boolean; message: string } | null;

export async function saveClassTypeInstructors(
  _prev: TypeState, fd: FormData,
): Promise<TypeState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("class_type_id") ?? "");
  const ids = String(fd.get("instructor_ids") ?? "").split(",").filter(Boolean);

  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_class_type_instructors", {
    p_class_type_id: id, p_instructor_ids: ids,
  });
  if (error) {
    return {
      ok: false,
      message: /PT403/.test(error.message)
        ? "Only owners and managers can change this."
        : /PT404/.test(error.message) ? "That class type no longer exists."
        : error.message,
    };
  }

  revalidatePath(`/class-types/${id}`);
  revalidatePath("/schedule");
  const n = Number(data ?? 0);
  return {
    ok: true,
    message: n === 0
      ? "Saved. Nobody is down to teach it, so the scheduler will leave these open."
      : `Saved — ${n} instructor${n === 1 ? "" : "s"}.`,
  };
}
