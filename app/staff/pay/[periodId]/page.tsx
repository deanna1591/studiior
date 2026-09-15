import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { money } from "@/lib/dashboard";
import MarkPaid from "./mark-paid";

export const dynamic = "force-dynamic";

type Sum = { instructor_id: string; instructor_name: string; total_cents: number; held_cents: number };
type Export = { starts_on: string; ends_on: string; status: string; currency: string; settle_on?: string | null; summary: Sum[] };

export default async function PayPeriod({ params }: { params: { periodId: string } }) {
  const screen = await staffScreen("/pay");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Pay"><Denied what="Payroll" role={ctx.role} /></AppShell>;

  const [{ data }, { data: settlements }] = await Promise.all([
    supabase.rpc("pay_period_export", { p_period_id: params.periodId }),
    supabase.from("instructor_pay_settlements").select("instructor_id, paid_on, method").eq("period_id", params.periodId),
  ]);
  const e = data as unknown as Export | null;
  if (!e) return <AppShell {...shell} title="Pay"><p className="text-[13px] text-ink-2">Period not found.</p></AppShell>;
  const paidBy = new Map((settlements ?? []).map((s) => [s.instructor_id, s]));
  const closed = e.status === "closed";
  const d = (iso: string) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));

  return (
    <AppShell {...shell} title="Pay period"
      actions={closed ? <a href={`/pay/${params.periodId}/export`} className="rounded-full border border-line-2 bg-surface px-4 py-2 text-[13px] font-semibold text-ink">Export CSV</a> : undefined}>
      <Link href="/pay" className="mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">← All periods</Link>
      <p className="mb-4 text-[13px] text-ink-2">{d(e.starts_on)} – {d(e.ends_on)} · <span className="s-tag">{e.status}</span>
        {e.settle_on && <> · pays <span className="font-medium text-ink">{d(e.settle_on)}</span></>}</p>
      {!closed && <p className="mb-4 max-w-2xl text-[13px] text-ink-2">This period is still open. Close it (from an instructor's statement) before recording payments; a CSV is available once it is closed, so it matches the final figures.</p>}

      {(e.summary ?? []).length === 0 ? (
        <p className="text-[13px] text-ink-2">No pay recorded in this period yet.</p>
      ) : (
        <ul className="s-card max-w-2xl divide-y divide-line overflow-hidden">
          {(e.summary ?? []).map((s) => {
            const paid = paidBy.get(s.instructor_id);
            return (
              <li key={s.instructor_id} className="px-4 py-3">
                <div className="flex items-center justify-between gap-3">
                  <span className="text-[14px] text-ink">{s.instructor_name}</span>
                  <span className="num text-[14px] font-semibold text-ink">{money(s.total_cents, e.currency)}</span>
                </div>
                {s.held_cents > 0 && <p className="mt-0.5 text-[12px] text-ink-2">{money(s.held_cents, e.currency)} held — unconfirmed.</p>}
                {paid
                  ? <p className="mt-1 text-[12px]" style={{ color: "var(--lime-text)" }}>Paid {d(paid.paid_on)} · {paid.method.replace("_", " ")}</p>
                  : closed
                  ? <MarkPaid periodId={params.periodId} instructorId={s.instructor_id} paid={null} />
                  : null}
              </li>
            );
          })}
        </ul>
      )}
    </AppShell>
  );
}
