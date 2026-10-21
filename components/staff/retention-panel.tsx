"use client";

import { useEffect, useState, useTransition } from "react";
import EmailComposer from "@/components/staff/email-composer";
import { stateLine, SNOOZE_DAYS, snoozeLabel } from "@/lib/retention";
import {
  fetchSnapshot, prefillEmail, sendEmail, sendTest, logContact, snooze, dismiss,
} from "@/app/staff/retention/actions";

type Snapshot = Record<string, any>;

export type PanelRow = {
  member_id: string;
  situation: "unconverted" | "at_risk" | "drifting" | "expiring" | "lapsed";
  member_name: string;
  phone: string | null;
  task_id: string | null;
  suggested_message: string | null;
};

function Copy({ value, children }: { value: string; children: React.ReactNode }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button"
      onClick={async () => { try { await navigator.clipboard.writeText(value); setDone(true); setTimeout(() => setDone(false), 1500); } catch {} }}
      className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">
      {done ? "Copied" : children}
    </button>
  );
}

function d(iso: string | null | undefined) {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short" }).format(new Date(iso));
}

export default function RetentionPanel({
  studioId, studioName, row, onClose,
}: { studioId: string; studioName: string; row: PanelRow; onClose: () => void }) {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [mode, setMode] = useState<"view" | "email">("view");
  const [subject, setSubject] = useState("");
  const [body, setBody] = useState("");
  const [note, setNote] = useState<string | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    let live = true;
    fetchSnapshot(row.member_id).then((s) => { if (live) setSnap(s); });
    return () => { live = false; };
  }, [row.member_id]);

  async function openEmail() {
    setNote(null);
    const pre = await prefillEmail(studioId, row.member_id, row.situation);
    setSubject(pre.subject); setBody(pre.body); setMode("email");
  }

  const contact = snap?.last_contact as any;

  return (
    <div className="fixed inset-0 z-40 flex justify-end" role="dialog" aria-modal="true">
      <button aria-label="Close" className="flex-1 bg-black/20" onClick={onClose} />
      <div className="h-full w-full max-w-md overflow-y-auto bg-surface shadow-xl">
        <div className="flex items-start justify-between gap-2 border-b border-line px-4 py-3">
          <div>
            <div className="text-[15px] font-semibold text-ink">{row.member_name}</div>
            {snap && <div className="mt-0.5 text-[12.5px] text-ink-2">{stateLine(snap)}</div>}
          </div>
          <button onClick={onClose} className="text-ink-3 hover:text-ink" aria-label="Close">✕</button>
        </div>

        {mode === "email" ? (
          <div className="px-4 py-3">
            <button onClick={() => setMode("view")} className="mb-2 text-[12.5px] text-ink-2 hover:text-ink">← Back</button>
            <EmailComposer
              subject={subject} onSubject={setSubject} body={body} onBody={setBody}
              studioName={studioName}
              onSendTest={async () => {
                const r = await sendTest(studioId, subject, body);
                return r.ok ? { sentence: `Sent a test to ${r.to}.` } : { error: r.error ?? "Could not send the test." };
              }}
              actions={
                <button
                  disabled={pending}
                  onClick={() => start(async () => {
                    const r = await sendEmail(row.member_id, row.situation, subject, body);
                    if (r.ok) { setNote("Sent."); setMode("view"); fetchSnapshot(row.member_id).then(setSnap); }
                    else setNote(r.reason === "muted" ? "They have turned off sequence emails."
                                 : r.reason === "duplicate" ? "Already emailed today."
                                 : r.reason === "no_email" ? "No email on file." : "Could not send.");
                  })}
                  className="rounded-md px-3 py-1.5 text-[13px] font-medium"
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                  {pending ? "Sending…" : "Send"}
                </button>
              }
            />
            {note && <p className="mt-2 text-[12.5px] text-ink-2">{note}</p>}
          </div>
        ) : (
          <div className="px-4 py-3">
            {/* Contact details */}
            <div className="flex flex-wrap items-center gap-2 text-[12.5px] text-ink-2">
              {row.phone && <Copy value={row.phone}>{row.phone}</Copy>}
              {snap?.email && <Copy value={String(snap.email)}>{String(snap.email)}</Copy>}
            </div>

            {/* Snapshot facts */}
            <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5 text-[12.5px]">
              <Fact k="Last visit" v={snap ? d(snap.last_visit_at) : "…"} />
              <Fact k="Visits (30 days)" v={snap ? String(snap.visits_30d ?? 0) : "…"} />
              <Fact k="Usual class" v={snap?.usual_class ?? "—"} />
              <Fact k="Usual instructor" v={snap?.usual_instructor ?? "—"} />
              {snap?.current_plan_name && <Fact k="Plan" v={String(snap.current_plan_name)} />}
              {snap?.credits_remaining != null && <Fact k="Credits" v={String(snap.credits_remaining)} />}
            </dl>

            {snap?.task && (snap.task as any).reason && (
              <p className="mt-3 rounded-md border border-line px-3 py-2 text-[12.5px] text-ink-2">
                Task: {(snap.task as any).reason}
              </p>
            )}
            {contact && (
              <p className="mt-2 text-[12px] text-ink-3">
                Last contact: {d(contact.at)} {contact.by ? `by ${contact.by}` : ""} ({contact.method})
                {contact.outcome && contact.outcome !== "none" ? ` · outcome: ${contact.outcome}` : ""}
              </p>
            )}

            {/* Actions */}
            <div className="mt-4 flex flex-wrap gap-2">
              <button onClick={openEmail}
                className="rounded-md px-3 py-1.5 text-[13px] font-medium"
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                Email
              </button>
              {row.suggested_message && <Copy value={row.suggested_message}>Copy Viber message</Copy>}
            </div>

            <div className="mt-3">
              <div className="text-[12px] text-ink-3">Mark contacted</div>
              <div className="mt-1 flex flex-wrap gap-2">
                {(["viber", "call", "in_person"] as const).map((mth) => (
                  <button key={mth} disabled={pending}
                    onClick={() => start(async () => { await logContact(row.member_id, row.situation, mth); setNote("Logged."); fetchSnapshot(row.member_id).then(setSnap); })}
                    className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">
                    {mth === "in_person" ? "In person" : mth === "viber" ? "Viber" : "Call"}
                  </button>
                ))}
              </div>
            </div>

            <div className="mt-3">
              <div className="text-[12px] text-ink-3">Snooze</div>
              <div className="mt-1 flex flex-wrap gap-2">
                {SNOOZE_DAYS.map((n) => (
                  <button key={n} disabled={pending}
                    onClick={() => start(async () => { await snooze(row.task_id, row.member_id, row.situation, n); setNote(snoozeLabel(n) + "."); onClose(); })}
                    className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">
                    {n} days
                  </button>
                ))}
              </div>
            </div>

            <div className="mt-4 flex items-center justify-between">
              <a href={`/members/${row.member_id}`} className="text-[12.5px] font-medium text-ink underline underline-offset-4">
                Open full profile
              </a>
              {row.task_id && (
                <button onClick={() => start(async () => { await dismiss(row.task_id!); onClose(); })}
                  className="text-[12px] text-ink-3 hover:text-ink">Dismiss</button>
              )}
            </div>

            {/* Last five journey lines */}
            {Array.isArray(snap?.journey) && snap.journey.length > 0 && (
              <div className="mt-4 border-t border-line pt-3">
                <div className="text-[12px] text-ink-3">Recent</div>
                <ul className="mt-1 space-y-1">
                  {snap.journey.slice(0, 5).map((j: any, i: number) => (
                    <li key={i} className="flex justify-between gap-2 text-[12.5px] text-ink-2">
                      <span className="min-w-0 truncate">{j.title}</span>
                      <span className="shrink-0 text-ink-3">{d(j.at)}</span>
                    </li>
                  ))}
                </ul>
              </div>
            )}
            {note && <p className="mt-3 text-[12.5px] text-ink-2">{note}</p>}
          </div>
        )}
      </div>
    </div>
  );
}

function Fact({ k, v }: { k: string; v: string }) {
  return (<><dt className="text-ink-3">{k}</dt><dd className="text-ink">{v}</dd></>);
}
