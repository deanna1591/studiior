"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type ComposeState = { error: string } | null;

/**
 * Save the draft, then queue it — two statements, in that order, always.
 *
 * Business Rules §11: nothing drafted goes out without a person reading it.
 * That rule is kept here by there being no other way in: the body that gets
 * queued is the body the form posted, so whatever the owner edited is what
 * leaves. There is no path that queues message_draft_for()'s output directly,
 * and adding one would be the bug.
 */
export async function sendMessage(_prev: ComposeState, fd: FormData): Promise<ComposeState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };

  const memberId = String(fd.get("member_id") ?? "");
  const subject = String(fd.get("subject") ?? "").trim();
  const body = String(fd.get("body") ?? "").trim();
  const templateKey = String(fd.get("template_key") ?? "") || null;

  if (!subject) return { error: "Give it a subject — it is the first thing they see." };
  if (!body) return { error: "The message is empty." };

  const supabase = createClient();

  const { data: draft, error: insertError } = await supabase
    .from("messages")
    .insert({
      studio_id: ctx.studioId,
      member_id: memberId,
      subject,
      body,
      template_key: templateKey,
      created_by: ctx.userId,
      status: "draft",
    })
    .select("id")
    .single();

  if (insertError) {
    return /row-level security/i.test(insertError.message)
      ? { error: "Your role cannot message members. Owners, managers and front desk can." }
      : { error: insertError.message };
  }

  const { error: sendError } = await supabase.rpc("send_message", { p_message_id: draft.id });
  if (sendError) {
    // The draft exists and is not queued; saying so beats a bare error, because
    // the owner's words are not lost.
    if (sendError.code === "PT403") {
      return { error: "Your role cannot send messages. Owners, managers and front desk can." };
    }
    return { error: `${sendError.message} The draft has been saved.` };
  }

  revalidatePath(`/members/${memberId}`);
  redirect(`/members/${memberId}?sent=1`);
}
