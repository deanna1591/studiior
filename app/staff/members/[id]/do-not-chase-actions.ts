"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

/** Decision 112 — set a member's do-not-chase flag. Manager-up via the members
 *  RLS; a refused update changes no rows and is reported. */
export async function setDoNotChase(
  memberId: string, on: boolean,
): Promise<{ ok: true } | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.from("members")
    .update({ do_not_chase: on }).eq("id", memberId).select("id");
  if (error) return { error: error.message };
  if (!data?.length) return { error: "Nothing was saved. Owners and managers only." };
  revalidatePath("/members/[id]", "page");
  return { ok: true };
}
