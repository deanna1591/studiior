"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type GiftAdminState = { ok: boolean; message: string } | null;

export async function voidGift(_prev: GiftAdminState, fd: FormData): Promise<GiftAdminState> {
  const id = String(fd.get("gift_card_id") ?? "");
  const reason = String(fd.get("reason") ?? "").trim();
  if (!id) return { ok: false, message: "No gift card chosen." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("gift_card_void", { p_gift_card_id: id, p_reason: reason });
  if (error) {
    if (/PT403/.test(error.message)) return { ok: false, message: "Only owners and managers can void a gift card." };
    if (/PT400/.test(error.message)) return { ok: false, message: "Give a reason." };
    if (/PT409/.test(error.message)) return { ok: false, message: "That card is already claimed or void." };
    return { ok: false, message: "That could not be done." };
  }
  revalidatePath("/gift-cards");
  return { ok: !!(data as { ok?: boolean })?.ok, message: "Voided." };
}

export async function resendGift(_prev: GiftAdminState, fd: FormData): Promise<GiftAdminState> {
  const id = String(fd.get("gift_card_id") ?? "");
  if (!id) return { ok: false, message: "No gift card chosen." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("gift_card_resend", { p_gift_card_id: id });
  if (error) {
    if (/PT403/.test(error.message)) return { ok: false, message: "Only owners and managers can resend a gift card." };
    if (/PT409/.test(error.message)) return { ok: false, message: "That card can't be resent." };
    return { ok: false, message: "That could not be done." };
  }
  revalidatePath("/gift-cards");
  return { ok: !!(data as { ok?: boolean })?.ok, message: "Sent again." };
}
