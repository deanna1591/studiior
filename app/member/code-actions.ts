"use server";

import { createClient } from "@/lib/supabase/server";
import { getMemberContext } from "@/lib/auth";
import { previewFromPrice, type CodePreview } from "@/lib/discount-code";

/**
 * Decision 120: check a code for the signed-in member, for a plan or a private
 * session type. Writes nothing except the rate-limit log.
 */
export async function previewMemberCode(input: {
  code: string; planId?: string | null; privateTypeId?: string | null;
}): Promise<CodePreview> {
  const ctx = await getMemberContext();
  if (!ctx) return previewFromPrice(null);
  const supabase = createClient();
  const { data, error } = await supabase.rpc("discount_code_preview", {
    p_studio_id: ctx.studioId, p_code: input.code,
    p_plan_id: (input.planId ?? null) as string,
    p_private_type_id: (input.privateTypeId ?? null) as string,
  });
  if (error) return { ...previewFromPrice(null), message: "That code couldn't be checked. Try again." };
  return previewFromPrice(data as Record<string, unknown>);
}
