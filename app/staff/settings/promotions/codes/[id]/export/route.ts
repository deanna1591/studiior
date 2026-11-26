import { NextResponse } from "next/server";
import { getStaffContext, isManagerUp } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const cell = (v: unknown) => {
  const s = v == null ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/** Decision 120: one batch's codes as CSV: code, state, used by, email, when, plan, amount off. */
export async function GET(_req: Request, { params }: { params: { id: string } }) {
  const ctx = await getStaffContext();
  if (!ctx || !isManagerUp(ctx.role)) return new NextResponse("Not allowed", { status: 403 });
  const supabase = createClient();
  const { data, error } = await supabase.rpc("discount_code_rows", { p_batch_id: params.id });
  if (error) return new NextResponse("Not found", { status: 404 });
  const rows = (data ?? []) as Record<string, unknown>[];
  const lines = [["code", "state", "used_by", "email", "used_at", "plan", "amount_off"].join(",")]
    .concat(rows.map((r) => [r.code, r.state, r.used_by, r.used_email, r.used_at, r.plan,
      r.amount_off_cents ? (Number(r.amount_off_cents) / 100).toFixed(2) : ""].map(cell).join(",")));
  return new NextResponse(lines.join("\n") + "\n", {
    headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": `attachment; filename="discount-codes-${params.id.slice(0, 8)}.csv"` },
  });
}
