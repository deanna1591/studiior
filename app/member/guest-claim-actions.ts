"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getMemberContext } from "@/lib/auth";
import { claimWaitingPlans } from "@/lib/guest-claim";
import { INTRO_REFUNDED_SENTENCE } from "@/lib/plan-kind";

/** Decision 118: the Home card's "Add it to my account". */
export async function claimGuestPlans(): Promise<{ message: string }> {
  const ctx = await getMemberContext();
  if (!ctx) return { message: "Please sign in again." };
  const r = await claimWaitingPlans(createClient(), ctx.studioId);
  revalidatePath("/");
  if (r.claimed.length > 0) return { message: `Your ${r.claimed[0]} is ready.` };
  if (r.refunded.length > 0) return { message: INTRO_REFUNDED_SENTENCE };
  return { message: "Nothing to add right now." };
}
