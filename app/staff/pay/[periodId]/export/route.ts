import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

type Row = { instructor_name: string; date: string; time: string | null; name: string | null;
  status: string | null; headcount: number | null; rate_version_id: string | null;
  amount_cents: number; category: string };
type Sum = { instructor_name: string; total_cents: number };

const esc = (v: unknown) => {
  const s = v == null ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
const money = (c: number) => (c / 100).toFixed(2);

export async function GET(_req: Request, { params }: { params: { periodId: string } }) {
  const ctx = await getStaffContext();
  if (!ctx) return new Response("Not signed in", { status: 401 });
  const supabase = createClient();
  const { data, error } = await supabase.rpc("pay_period_export", { p_period_id: params.periodId });
  if (error) return new Response(error.message, { status: 403 });
  const e = data as unknown as { starts_on: string; ends_on: string; currency: string; rows: Row[]; summary: Sum[] };

  const head = ["Instructor", "Date", "Time", "Class", "Status", "Headcount", "Rate version", "Amount", "Category"];
  const lines = [head.map(esc).join(",")];
  for (const r of e.rows ?? []) {
    lines.push([r.instructor_name, r.date, r.time ?? "", r.name ?? "", r.status ?? "", r.headcount ?? "",
      r.rate_version_id ?? "", money(r.amount_cents), r.category].map(esc).join(","));
  }
  lines.push("");
  lines.push(["Instructor", "Total"].map(esc).join(","));
  for (const s of e.summary ?? []) lines.push([s.instructor_name, money(s.total_cents)].map(esc).join(","));

  return new Response(lines.join("\n"), {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="payroll-${e.starts_on}-to-${e.ends_on}.csv"`,
    },
  });
}
