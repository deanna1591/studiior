import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import PayStatementView, { type Statement } from "@/components/pay/statement";
import { formatMoney } from "@/lib/plans";
import { fmtClock } from "@/lib/time";
import { markGuide } from "../actions";
import GuideHint from "@/components/instructor/guide-hint";
import { HINTS } from "@/lib/instructor-guide";

export const dynamic = "force-dynamic";

type Period = { period_id: string; starts_on: string; ends_on: string; status: string };
type DeskPayment = { paid_at: string; member_name: string; amount_cents: number;
  currency: string; method: string; reference: string | null; kind: string };

const METHOD_LABEL: Record<string, string> = { gcash: "GCash", cash: "Cash", card_terminal: "Card" };

/**
 * Decision 81a(d) — the desk payments THIS instructor recorded (last 60 days),
 * so they can reconcile the terminal and GCash at end of day. Money they took
 * for the studio; NOT part of their pay. Read-only; from my_desk_payments
 * (scoped to recorded_by = the caller).
 */
function DeskPayments({ rows, tz, fmt }: { rows: DeskPayment[]; tz: string; fmt: "12h" | "24h" }) {
  if (rows.length === 0) return null;
  return (
    <div className="mt-6">
      <p className="text-[15px] font-semibold leading-5 text-ink">Desk payments you took</p>
      <p className="m-sub mt-0.5 text-ink-3">Money you took at the desk for the studio. Not part of your pay.</p>
      <ul className="mt-2 space-y-1.5">
        {rows.map((p, i) => (
          <li key={i} className="m-card flex items-center justify-between px-3 py-2.5">
            <span className="min-w-0">
              <span className="block truncate text-[14px] leading-5 text-ink">{p.member_name}</span>
              <span className="m-sub block text-ink-3">
                <span className="num">{new Intl.DateTimeFormat("en-GB", { timeZone: tz, day: "numeric", month: "short" }).format(new Date(p.paid_at))}</span>
                {" "}<span className="num">{fmtClock(p.paid_at, tz, fmt)}</span>
                {" · "}{METHOD_LABEL[p.method] ?? p.method}{p.kind === "plan" ? " · plan" : p.kind === "drop-in" ? " · drop-in" : ""}
                {p.reference ? ` · ${p.reference}` : ""}
              </span>
            </span>
            <span className="num shrink-0 pl-2 text-[14px] text-ink">{formatMoney(p.amount_cents, p.currency)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

const dmy = (iso: string) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short" })
    .format(new Date(`${iso}T00:00:00Z`));

/**
 * MY PAY — Decision 75b-2 (i). A per-period statement from pay_statement (the
 * one source; instructor_pay_summary is retired from this page, left in the DB
 * to retire later). The picker lists the instructor's own periods Open/Closed/
 * Paid, newest first, defaulting to the current one. THEIRS TO READ, never to
 * change — if a line looks wrong, the footer opens an email to the studio.
 */
export default async function PayPage({ searchParams }: { searchParams: { period?: string } }) {
  const { ctx, supabase } = await instructorScreen();

  const [{ data: periodsData }, { data: studio }, { data: deskData }, { data: settings }] = await Promise.all([
    supabase.rpc("instructor_pay_periods", { p_instructor_id: ctx.instructor_id }),
    supabase.from("studios").select("contact_email, timezone").eq("id", ctx.studio_id).maybeSingle(),
    supabase.rpc("my_desk_payments"),
    supabase.from("studio_settings").select("time_format").eq("studio_id", ctx.studio_id).maybeSingle(),
  ]);
  const periods = (periodsData ?? []) as Period[];
  const contactEmail = studio?.contact_email ?? null;
  const tz = studio?.timezone ?? "UTC";
  const fmt = (settings?.time_format === "12h" ? "12h" : "24h") as "12h" | "24h";
  const desk = (deskData ?? []) as DeskPayment[];

  if (periods.length === 0) {
    return (
      <InstructorShell ctx={ctx} title="My pay">
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nothing to show yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            Once your studio opens a pay period, every class you teach lands here with what it paid.
          </p>
        </div>
        <DeskPayments rows={desk} tz={tz} fmt={fmt} />
      </InstructorShell>
    );
  }

  const selected = periods.find((p) => p.period_id === searchParams.period) ?? periods[0];
  const { data: stmtData } = await supabase.rpc("pay_statement", {
    p_instructor_id: ctx.instructor_id, p_period_id: selected.period_id,
  });
  const s = stmtData as Statement | null;

  const chipLabel = (p: Period) =>
    `${dmy(p.starts_on)}–${dmy(p.ends_on)}`;

  return (
    <InstructorShell ctx={ctx} title="My pay">
      {/* Decision 85: first-time hint on My pay. */}
      {!ctx.hints_seen?.pay && (
        <GuideHint text={HINTS.pay.text} refs={HINTS.pay.refs}
          onDismiss={async () => { "use server"; return markGuide("pay"); }} />
      )}
      {/* period picker — newest first, the selected one filled */}
      <div className="-mt-1 mb-3 flex flex-wrap gap-2">
        {periods.map((p) => {
          const on = p.period_id === selected.period_id;
          return (
            <Link key={p.period_id} href={`/instructor/pay?period=${p.period_id}`}
                  className="rounded-full px-3 py-1.5 text-[12px] font-semibold leading-4"
                  style={on
                    ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
                    : { background: "var(--surface)", color: "var(--ink-2)", border: "1px solid var(--line)" }}>
              {chipLabel(p)} · {p.status === "paid" ? "Paid" : p.status === "closed" ? "Closed" : "Open"}
            </Link>
          );
        })}
      </div>

      {s?.ok
        ? <div className="m-card px-4 py-4"><PayStatementView s={s} contactEmail={contactEmail} /></div>
        : <div className="m-card px-4 py-6"><p className="text-[15px] text-ink">This could not be read.</p></div>}

      <p className="m-sub mt-5 text-ink-3">
        These are the studio&rsquo;s figures. If something looks wrong, tell them — nothing here can be edited from this screen.
      </p>

      <DeskPayments rows={desk} tz={tz} fmt={fmt} />
    </InstructorShell>
  );
}
