import { createClient } from "@/lib/supabase/server";
import { getStaffContext, isManagerUp } from "@/lib/auth";
import { studioToday } from "@/lib/dashboard";

/**
 * Decision 49 — the filtered Sales table as a CSV.
 *
 * Same params as the screen (month, plan, status), same RPC, so the file is
 * what the manager is looking at. Manager-up — checked here and, the real
 * boundary, enforced by sales_history which raises PT403 for anyone else.
 */
type Row = {
  member_name: string; plan_name: string; plan_type: string;
  amount_cents: number; currency: string; payment_source: string;
  bought_on: string; starts_on: string | null; expires_on: string | null;
  sale_status: string;
};

const esc = (v: unknown) => {
  const s = v == null ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
const money = (c: number) => (c / 100).toFixed(2);

export async function GET(req: Request) {
  const ctx = await getStaffContext();
  if (!ctx) return new Response("Not signed in", { status: 401 });
  if (!isManagerUp(ctx.role)) return new Response("Sales are for owners and managers", { status: 403 });

  const url = new URL(req.url);
  const monthParam = url.searchParams.get("month");
  const ym = /^\d{4}-\d{2}$/.test(monthParam ?? "") ? monthParam! : studioToday(ctx.timeZone).slice(0, 7);
  const [yy, mm] = ym.split("-").map(Number);
  const lastDay = new Date(Date.UTC(yy, mm, 0)).getUTCDate();
  const from = `${ym}-01`;
  const to = `${ym}-${String(lastDay).padStart(2, "0")}`;
  const plan = url.searchParams.get("plan") || null;
  const status = url.searchParams.get("status") || null;

  const supabase = createClient();
  const { data, error } = await supabase.rpc("sales_history", {
    p_studio_id: ctx.studioId, p_from: from, p_to: to,
    p_plan_id: plan ?? undefined, p_status: status ?? undefined,
  });
  if (error) return new Response(error.message, { status: error.code === "PT403" ? 403 : 400 });

  const rows = (data ?? []) as Row[];
  const head = ["Member", "Plan", "Type", "Amount", "Currency", "Payment source",
    "Bought on", "Starts", "Expires", "Status"];
  const lines = [head.map(esc).join(",")];
  for (const r of rows) {
    lines.push([
      r.member_name, r.plan_name, r.plan_type, money(r.amount_cents), r.currency,
      r.payment_source, r.bought_on, r.starts_on ?? "", r.expires_on ?? "", r.sale_status,
    ].map(esc).join(","));
  }

  return new Response(lines.join("\n"), {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="sales-${ym}.csv"`,
    },
  });
}
