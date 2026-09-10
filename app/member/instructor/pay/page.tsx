import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { money } from "@/lib/dashboard";

export const dynamic = "force-dynamic";

type Record_ = {
  id: string; name: string | null; local_when: string;
  amount_cents: number; base_cents: number | null; per_head_cents: number | null;
  bonus_cents: number | null; head_count: number | null; kind: string;
  occurrence_status: string | null; cancellation_cause: string | null; did_not_run: boolean;
};
type Pay = {
  state: "ok" | "empty" | "no_period"; currency: string;
  period?: { starts_on: string; ends_on: string; status: string };
  total_cents?: number; classes_paid?: number; not_running_paid?: number;
  records?: Record_[]; empty_hint: string; read_only?: string;
};

/**
 * MY PAY — Decision 22 built the records and the period statement and gave
 * them no screen. Instructors will check this more than anything else here.
 *
 * THEIRS TO READ AND NEVER TO CHANGE. Every figure comes from
 * instructor_pay_records, written once by a trigger at the terminal
 * transition; nothing on this screen computes pay, and there is no control
 * that could alter one. If a figure looks wrong the answer is a conversation
 * with the studio, and the screen says so rather than offering a button that
 * would quietly disagree with the studio's books.
 *
 * A NOT-RUNNING CLASS IS ITEMISED, with what it paid. That is the whole
 * argument for guarantee tiers — a class that did not run and still paid a
 * holding rate is the number an instructor most wants to see and least expects.
 */
export default async function PayPage() {
  const { ctx, supabase } = await instructorScreen();
  const { data, error } = await supabase.rpc("instructor_pay_summary", {
    p_instructor_id: ctx.instructor_id,
  });
  const p = data as Pay | null;

  const d = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", day: "numeric", month: "short" })
      .format(new Date(`${iso}T00:00:00Z`));

  return (
    <InstructorShell ctx={ctx} title="My pay">
      {error && (
        <div className="m-card border-l-[3px] px-3 py-2.5" style={{ borderLeftColor: "var(--coral)" }}>
          <p className="text-[15px] leading-6 text-ink">This could not be read.</p>
          <p className="num mt-1 text-[11px] leading-4 text-ink-2">{error.message}</p>
        </div>
      )}

      {!p ? null : p.state === "no_period" || p.state === "empty" ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nothing to show yet.</p>
          <p className="m-sub mt-1 text-ink-2">{p.empty_hint}</p>
        </div>
      ) : (
        <>
          <div className="m-card px-4 py-4">
            <p className="m-sub text-ink-3">
              {d(p.period!.starts_on)} – {d(p.period!.ends_on)}
              {p.period!.status === "open" ? " · still open" : " · closed"}
            </p>
            <p className="m-stat mt-1 text-ink">{money(p.total_cents ?? 0, p.currency)}</p>
            <p className="m-sub mt-1 text-ink-2">
              <span className="num">{p.classes_paid}</span>{" "}
              {p.classes_paid === 1 ? "class" : "classes"} taught
              {(p.not_running_paid ?? 0) > 0 && (
                <> · <span className="num">{p.not_running_paid}</span> paid that did not run</>
              )}
            </p>
          </div>

          <ul className="mt-3 space-y-2">
            {(p.records ?? []).map((r) => (
              <li key={r.id} className="m-card px-3 py-2.5">
                <div className="flex items-baseline gap-3">
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-[15px] leading-5 text-ink">
                      {r.name ?? "Class"}
                    </span>
                    <span className="m-sub block text-ink-3">{r.local_when}</span>
                  </span>
                  <span className="num shrink-0 text-[15px] font-semibold leading-5 text-ink">
                    {money(r.amount_cents, p.currency)}
                  </span>
                </div>

                {r.did_not_run ? (
                  <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
                    Did not run
                    {r.cancellation_cause === "unmet_minimum" && " — it was short of its minimum"}
                    {r.cancellation_cause === "studio_fault" && " — the studio cancelled it"}
                    {r.cancellation_cause === "force_majeure" && " — it was called off"}
                    . You were paid anyway.
                  </p>
                ) : (
                  <p className="mt-1.5 text-[12px] leading-[17px] text-ink-3">
                    {r.base_cents ? <>base {money(r.base_cents, p.currency)}</> : null}
                    {r.per_head_cents ? <> · {money(r.per_head_cents, p.currency)} per head</> : null}
                    {r.head_count != null ? <> · <span className="num">{r.head_count}</span> in</> : null}
                    {r.bonus_cents ? <> · bonus {money(r.bonus_cents, p.currency)}</> : null}
                  </p>
                )}
              </li>
            ))}
          </ul>

          <p className="m-sub mt-5 text-ink-3">{p.read_only}</p>
        </>
      )}
    </InstructorShell>
  );
}
