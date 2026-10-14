"use client";

import { useState } from "react";
import { StateChip } from "@/components/state-chip";
import { markContacted, dismissRetentionTask } from "./actions";

export type RetentionRow = {
  section: "unconverted" | "expiring" | "lapsed";
  member_id: string;
  member_name: string;
  phone: string | null;
  class_label: string;
  days_since: number;
  instructor_name: string | null;
  offer_label: string | null;
  plan_name: string | null;
  date_label: string | null;
  task_id: string | null;
  task_status: string | null;
  suggested_message: string | null;
};

function Copy({ value, label }: { value: string; label: string }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button"
      onClick={async () => {
        try { await navigator.clipboard.writeText(value); setDone(true); setTimeout(() => setDone(false), 1500); } catch {}
      }}
      className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">
      {done ? "Copied" : label}
    </button>
  );
}

function Name({ r }: { r: RetentionRow }) {
  return (
    <td className="py-2.5 pr-3">
      <div className="font-medium text-ink">{r.member_name}</div>
      {r.phone && <div className="mt-0.5"><Copy value={r.phone} label={r.phone} /></div>}
    </td>
  );
}

function Unconverted({ rows }: { rows: RetentionRow[] }) {
  return (
    <table className="w-full min-w-[720px] border-collapse text-[13px]">
      <thead>
        <tr className="border-b border-line text-left text-[12px] text-ink-3">
          <th className="py-2 pr-3 font-medium">Member</th>
          <th className="py-2 pr-3 font-medium">Free class</th>
          <th className="py-2 pr-3 font-medium">Instructor</th>
          <th className="py-2 pr-3 font-medium">Offer ends</th>
          <th className="py-2 pr-3 font-medium">Status</th>
          <th className="py-2 pr-3 font-medium"></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.member_id} className="border-b border-line align-top">
            <Name r={r} />
            <td className="py-2.5 pr-3 text-ink-2">
              {r.class_label}
              <div className="text-[12px] text-ink-3">{r.days_since} day{r.days_since === 1 ? "" : "s"} ago</div>
            </td>
            <td className="py-2.5 pr-3 text-ink-2">{r.instructor_name || "—"}</td>
            <td className="py-2.5 pr-3 text-ink-2">{r.offer_label ?? "—"}</td>
            <td className="py-2.5 pr-3">
              {r.task_status ? <StateChip state={r.task_status === "contacted" ? "contacted" : "open"} /> : <span className="text-ink-3">—</span>}
            </td>
            <td className="py-2.5 pr-3">
              <div className="flex flex-wrap items-center gap-1.5">
                {r.suggested_message && <Copy value={r.suggested_message} label="Copy message" />}
                {r.task_id && r.task_status === "open" && (
                  <>
                    <form action={markContacted}>
                      <input type="hidden" name="task_id" value={r.task_id} />
                      <button className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">Contacted</button>
                    </form>
                    <form action={dismissRetentionTask}>
                      <input type="hidden" name="task_id" value={r.task_id} />
                      <button className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-3 hover:text-ink">Dismiss</button>
                    </form>
                  </>
                )}
              </div>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function PlanRows({ rows, dateHead }: { rows: RetentionRow[]; dateHead: string }) {
  return (
    <table className="w-full min-w-[480px] border-collapse text-[13px]">
      <thead>
        <tr className="border-b border-line text-left text-[12px] text-ink-3">
          <th className="py-2 pr-3 font-medium">Member</th>
          <th className="py-2 pr-3 font-medium">Plan</th>
          <th className="py-2 pr-3 font-medium">{dateHead}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.member_id} className="border-b border-line align-top">
            <Name r={r} />
            <td className="py-2.5 pr-3 text-ink-2">{r.plan_name ?? "—"}</td>
            <td className="py-2.5 pr-3 text-ink-2">{r.date_label ?? "—"}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mb-7">
      <h2 className="mb-2 text-[13px] font-semibold text-ink">{title}</h2>
      <div className="overflow-x-auto">{children}</div>
    </section>
  );
}

export default function RetentionBoard({ rows }: { rows: RetentionRow[] }) {
  const unconverted = rows.filter((r) => r.section === "unconverted");
  const expiring = rows.filter((r) => r.section === "expiring");
  const lapsed = rows.filter((r) => r.section === "lapsed");
  if (rows.length === 0) {
    return <p className="text-[13px] text-ink-2">Nothing needs chasing right now.</p>;
  }
  return (
    <>
      <Section title="Free class, not yet converted">
        {unconverted.length ? <Unconverted rows={unconverted} />
          : <p className="text-[13px] text-ink-3">No free-class members waiting to convert.</p>}
      </Section>
      {expiring.length > 0 && (
        <Section title="Expiring this week"><PlanRows rows={expiring} dateHead="Ends" /></Section>
      )}
      {lapsed.length > 0 && (
        <Section title="Lapsed this month"><PlanRows rows={lapsed} dateHead="Ended" /></Section>
      )}
    </>
  );
}
