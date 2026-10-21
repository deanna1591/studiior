"use client";

import { useState, useTransition } from "react";
import { StateChip } from "@/components/state-chip";
import EmailComposer from "@/components/staff/email-composer";
import { outcomeLine } from "@/lib/retention";
import RetentionPanel, { type PanelRow } from "@/components/staff/retention-panel";
import { prefillBulk, sendBulk, sendTest } from "./actions";

export type RetentionRow = {
  section: "unconverted" | "drifting" | "at_risk" | "expiring" | "lapsed";
  member_id: string;
  member_name: string;
  phone: string | null;
  class_label: string;
  days_since: number;
  instructor_name: string | null;
  offer_label: string | null;
  plan_name: string | null;
  date_label: string | null;
  reason: string | null;
  task_id: string | null;
  task_status: string | null;
  suggested_message: string | null;
  last_contact_at: string | null;
  last_contact_method: string | null;
  outcome: string | null;
  outcome_days: number | null;
};

const SITUATION: Record<RetentionRow["section"], PanelRow["situation"]> = {
  unconverted: "unconverted", at_risk: "at_risk", drifting: "drifting",
  expiring: "expiring", lapsed: "lapsed",
};

function secondary(r: RetentionRow): string {
  switch (r.section) {
    case "unconverted":
      return `Free class ${r.class_label} · ${r.days_since} day${r.days_since === 1 ? "" : "s"} ago`
        + (r.instructor_name ? ` · ${r.instructor_name}` : "");
    case "at_risk":
    case "drifting":
      return r.reason ?? "—";
    case "expiring":
      return `${r.plan_name ?? "Plan"} · ends ${r.date_label ?? "—"}`;
    case "lapsed":
      return `${r.plan_name ?? "Plan"} · ended ${r.date_label ?? "—"}`;
  }
}

function Row({ r, selecting, checked, onCheck, onOpen }: {
  r: RetentionRow; selecting: boolean; checked: boolean;
  onCheck: (v: boolean) => void; onOpen: () => void;
}) {
  const out = outcomeLine({
    method: r.last_contact_method, contactedAt: r.last_contact_at,
    outcome: r.outcome, outcomeDays: r.outcome_days,
  });
  return (
    <li className="flex items-start gap-2 border-b border-line py-2.5">
      {selecting && (
        <input type="checkbox" checked={checked} aria-label={`Select ${r.member_name}`}
          onChange={(e) => onCheck(e.target.checked)} className="mt-1" />
      )}
      <button onClick={onOpen} className="min-w-0 flex-1 text-left">
        <div className="flex items-center gap-2">
          <span className="font-medium text-ink">{r.member_name}</span>
          {r.task_status && <StateChip state={r.task_status === "contacted" ? "contacted" : "open"} />}
        </div>
        <div className="mt-0.5 truncate text-[12.5px] text-ink-2">{secondary(r)}</div>
        {out && <div className="mt-0.5 text-[12px] text-ink-3">{out}</div>}
      </button>
    </li>
  );
}

function BulkComposer({
  studioId, studioName, situation, memberIds, onClose, onDone,
}: {
  studioId: string; studioName: string; situation: PanelRow["situation"];
  memberIds: string[]; onClose: () => void; onDone: (sentence: string) => void;
}) {
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [ready, setReady] = useState(false);
  const [tested, setTested] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [pending, start] = useTransition();

  // Pre-fill once, keeping placeholders so each member is rendered at send time.
  if (!ready) {
    prefillBulk(studioId, situation).then((t) => { setSubject(t.subject); setBody(t.body); setReady(true); });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4" role="dialog" aria-modal="true">
      <button aria-label="Close" className="absolute inset-0 bg-black/25" onClick={onClose} />
      <div className="relative max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-xl bg-surface p-4 shadow-xl">
        <div className="mb-2 flex items-center justify-between">
          <h3 className="text-[14px] font-semibold text-ink">Email {memberIds.length} member{memberIds.length === 1 ? "" : "s"}</h3>
          <button onClick={onClose} className="text-ink-3 hover:text-ink" aria-label="Close">✕</button>
        </div>
        <p className="mb-2 text-[12px] text-ink-3">
          One email each, rendered with that member&rsquo;s own details. Send a test first.
        </p>
        <EmailComposer
          subject={subject} onSubject={setSubject} body={body} onBody={setBody} studioName={studioName}
          onSendTest={async () => {
            const r = await sendTest(studioId, subject, body);
            if (r.ok) { setTested(true); return { sentence: `Sent a test to ${r.to}.` }; }
            return { error: r.error ?? "Could not send the test." };
          }}
          actions={
            <button disabled={pending || !tested}
              title={tested ? "" : "Send a test first"}
              onClick={() => start(async () => {
                const r = await sendBulk(studioId, memberIds, situation, subject, body);
                if ((r as any).error) { setNote((r as any).error); return; }
                onDone(`Emailed ${r.sent}. ${r.skipped.length ? `${r.skipped.length} skipped.` : ""}`);
              })}
              className="rounded-md px-3 py-1.5 text-[13px] font-medium disabled:opacity-50"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
              {pending ? "Sending…" : `Send to ${memberIds.length}`}
            </button>
          }
        />
        {note && <p className="mt-2 text-[12.5px] text-ink-2">{note}</p>}
      </div>
    </div>
  );
}

function Section({
  title, count, rows, studioId, studioName, onOpen, onBulkDone,
}: {
  title: string; count: string | null; rows: RetentionRow[];
  studioId: string; studioName: string;
  onOpen: (r: RetentionRow) => void; onBulkDone: (s: string) => void;
}) {
  const [selecting, setSelecting] = useState(false);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [bulk, setBulk] = useState(false);
  if (rows.length === 0) return null;
  const situation = SITUATION[rows[0].section];

  return (
    <section className="mb-7">
      <div className="mb-2 flex flex-wrap items-center gap-x-3 gap-y-1">
        <h2 className="text-[13px] font-semibold text-ink">{title}</h2>
        {count && <span className="text-[12px] text-ink-3">{count}</span>}
        <div className="ml-auto flex items-center gap-2">
          {selecting && picked.size > 0 && (
            <button onClick={() => setBulk(true)}
              className="rounded border border-line-2 px-2 py-0.5 text-[12px] font-medium text-ink hover:bg-paper">
              Email selected ({picked.size})
            </button>
          )}
          <button onClick={() => { setSelecting((v) => !v); setPicked(new Set()); }}
            className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">
            {selecting ? "Cancel" : "Select"}
          </button>
        </div>
      </div>
      <ul>
        {rows.map((r) => (
          <Row key={r.member_id} r={r} selecting={selecting} checked={picked.has(r.member_id)}
            onOpen={() => onOpen(r)}
            onCheck={(v) => setPicked((p) => {
              const n = new Set(p); if (v) n.add(r.member_id); else n.delete(r.member_id);
              if (n.size > 50) return p;  // cap
              return n;
            })} />
        ))}
      </ul>
      {bulk && (
        <BulkComposer studioId={studioId} studioName={studioName} situation={situation}
          memberIds={[...picked]} onClose={() => setBulk(false)}
          onDone={(s) => { setBulk(false); setSelecting(false); setPicked(new Set()); onBulkDone(s); }} />
      )}
    </section>
  );
}

export default function RetentionBoard({
  rows, studioId, studioName, outcomes,
}: {
  rows: RetentionRow[]; studioId: string; studioName: string;
  outcomes: { contacted: number; came_back: number };
}) {
  const [open, setOpen] = useState<RetentionRow | null>(null);
  const [flash, setFlash] = useState<string | null>(null);
  const by = (s: string) => rows.filter((r) => r.section === s);
  if (rows.length === 0) return <p className="text-[13px] text-ink-2">Nothing needs chasing right now.</p>;

  const monthCount = outcomes.contacted > 0
    ? `This month: ${outcomes.contacted} contacted → ${outcomes.came_back} came back` : null;

  return (
    <>
      {monthCount && (
        <p className="mb-4 inline-block rounded-md bg-paper px-3 py-1.5 text-[12.5px] text-ink-2">{monthCount}</p>
      )}
      {flash && <p className="mb-3 rounded-md border border-line px-3 py-2 text-[13px] text-ink-2">{flash}</p>}
      <Section title="Free class, not yet converted" count={null} rows={by("unconverted")}
        studioId={studioId} studioName={studioName} onOpen={setOpen} onBulkDone={setFlash} />
      <Section title="Drifting" count={null} rows={by("drifting")}
        studioId={studioId} studioName={studioName} onOpen={setOpen} onBulkDone={setFlash} />
      <Section title="At risk" count={null} rows={by("at_risk")}
        studioId={studioId} studioName={studioName} onOpen={setOpen} onBulkDone={setFlash} />
      <Section title="Expiring this week" count={null} rows={by("expiring")}
        studioId={studioId} studioName={studioName} onOpen={setOpen} onBulkDone={setFlash} />
      <Section title="Lapsed this month" count={null} rows={by("lapsed")}
        studioId={studioId} studioName={studioName} onOpen={setOpen} onBulkDone={setFlash} />
      {open && (
        <RetentionPanel studioId={studioId} studioName={studioName}
          row={{
            member_id: open.member_id, situation: SITUATION[open.section],
            member_name: open.member_name, phone: open.phone,
            task_id: open.task_id, suggested_message: open.suggested_message,
          }}
          onClose={() => setOpen(null)} />
      )}
    </>
  );
}
