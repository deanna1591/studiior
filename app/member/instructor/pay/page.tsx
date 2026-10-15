import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import PayStatementView, { type Statement } from "@/components/pay/statement";

export const dynamic = "force-dynamic";

type Period = { period_id: string; starts_on: string; ends_on: string; status: string };

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

  const [{ data: periodsData }, { data: studio }] = await Promise.all([
    supabase.rpc("instructor_pay_periods", { p_instructor_id: ctx.instructor_id }),
    supabase.from("studios").select("contact_email").eq("id", ctx.studio_id).maybeSingle(),
  ]);
  const periods = (periodsData ?? []) as Period[];
  const contactEmail = studio?.contact_email ?? null;

  if (periods.length === 0) {
    return (
      <InstructorShell ctx={ctx} title="My pay">
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nothing to show yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            Once your studio opens a pay period, every class you teach lands here with what it paid.
          </p>
        </div>
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
    </InstructorShell>
  );
}
