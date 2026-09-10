"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, buttonQuietClass, inputClass } from "@/components/ui";
import { previewClosure, applyClosure, reopen, type ClosureState, type PlainState } from "./actions";

function Go({ label, busy, quiet }: { label: string; busy: string; quiet?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button className={quiet ? buttonQuietClass : buttonClass} disabled={pending}>
      {pending ? busy : label}
    </button>
  );
}

/** Preview then apply, because closing CANCELS classes people are booked on. */
export default function CloseForm({ today }: { today: string }) {
  const [starts, setStarts] = useState(today);
  const [ends, setEnds] = useState(today);
  const [reason, setReason] = useState("");
  const [partial, setPartial] = useState(false);
  const [from, setFrom] = useState("14:00");
  const [to, setTo] = useState("18:00");

  const [prev, doPreview] = useFormState<ClosureState, FormData>(previewClosure, null);
  const [done, doApply] = useFormState<ClosureState, FormData>(applyClosure, null);
  const shown = done ?? prev;

  const hidden = (
    <>
      <input type="hidden" name="starts_on" value={starts} />
      <input type="hidden" name="ends_on" value={ends} />
      <input type="hidden" name="reason" value={reason} />
      {partial && <input type="hidden" name="partial" value="on" />}
      {partial && <input type="hidden" name="starts_at_time" value={from} />}
      {partial && <input type="hidden" name="ends_at_time" value={to} />}
    </>
  );

  return (
    <div className="max-w-xl">
      {shown && "error" in shown && <Notice kind="error">{shown.error}</Notice>}

      <form action={doPreview} className="space-y-4">
        {hidden}
        <div className="grid grid-cols-2 gap-3">
          <Field label="Closed from">
            <input type="date" required value={starts} className={inputClass}
                   onChange={(e) => {
                     setStarts(e.target.value);
                     if (ends < e.target.value) setEnds(e.target.value);
                   }} />
          </Field>
          <Field label="until, inclusive">
            <input type="date" required value={ends} className={inputClass}
                   onChange={(e) => setEnds(e.target.value)} />
          </Field>
        </div>

        <Field label="Reason" hint="A member sees this instead of an empty day, so write it for them.">
          <input required value={reason} className={inputClass} placeholder="Closed for Christmas"
                 onChange={(e) => setReason(e.target.value)} />
        </Field>

        <label className="flex items-start gap-2.5">
          <input type="checkbox" checked={partial} className="mt-0.5 h-4 w-4"
                 onChange={(e) => setPartial(e.target.checked)} />
          <span className="text-[13px] leading-[19px] text-ink-2">
            Only part of the day — a morning off, an afternoon deep clean. Classes
            outside these hours run as normal.
          </span>
        </label>
        {partial && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Closed from">
              <input type="time" value={from} className={inputClass}
                     onChange={(e) => setFrom(e.target.value)} />
            </Field>
            <Field label="until">
              <input type="time" value={to} className={inputClass}
                     onChange={(e) => setTo(e.target.value)} />
            </Field>
          </div>
        )}

        <Go label="See what closing does" busy="Working it out…" />
      </form>

      {shown && "result" in shown && (
        <Outcome result={shown.result} applied={done !== null}>
          <form action={doApply}>{hidden}<Go label="Close the studio" busy="Closing…" /></form>
        </Outcome>
      )}
    </div>
  );
}

function Outcome({
  result, applied, children,
}: {
  result: Extract<ClosureState, { result: unknown }>["result"];
  applied: boolean; children: React.ReactNode;
}) {
  if (result.ok) {
    return (
      <section className="mt-6 rounded border border-line bg-surface px-3.5 py-3">
        <p className="section-label text-ink-2">What happened</p>
        <p className="mt-1.5 text-[13px] leading-[19px] text-ink">
          {result.classes_cancelled === 0
            ? "Closed. There was nothing on the calendar to cancel."
            : <>Closed. <span className="num">{result.classes_cancelled}</span>{" "}
                {result.classes_cancelled === 1 ? "class" : "classes"} cancelled and{" "}
                <span className="num">{result.members_notified}</span>{" "}
                {result.members_notified === 1 ? "member" : "members"} emailed. Their
                credits have gone back, whatever the usual notice period is.</>}
        </p>
      </section>
    );
  }

  const heavy = result.members_booked > 0;
  return (
    <section className="mt-6 rounded border px-3.5 py-3"
             style={heavy
               ? { borderColor: "var(--coral)", background: "var(--coral-tint)" }
               : { borderColor: "var(--line)", background: "var(--surface)" }}>
      <p className="section-label text-ink-2">What this will do</p>
      <p className="mt-1.5 text-[13px] leading-[19px] text-ink">
        {result.classes === 0
          ? <>Nothing is on the calendar then, so closing only stops classes being
              made for it.</>
          : <>Closing {result.starts_on}
              {result.ends_on !== result.starts_on && <> to {result.ends_on}</>}
              {" "}cancels <span className="num">{result.classes}</span>{" "}
              {result.classes === 1 ? "class" : "classes"}.{" "}
              <span className="num">{result.members_booked}</span>{" "}
              {result.members_booked === 1 ? "member is" : "members are"} booked and
              will be emailed. Credits go back regardless of timing and no late fees
              are charged — the studio cancelled, not them.</>}
      </p>
      {result.detail.length > 0 && (
        <ul className="mt-2 space-y-1">
          {result.detail.slice(0, 12).map((d) => (
            <li key={d.occurrence_id} className="text-[13px] leading-[19px] text-ink-2">
              {d.name} — {d.local}
              {d.booked > 0 && <> — <span className="num">{d.booked}</span> booked</>}
            </li>
          ))}
          {result.detail.length > 12 && (
            <li className="text-[12.5px] leading-4 text-ink-3">
              and {result.detail.length - 12} more
            </li>
          )}
        </ul>
      )}
      {!applied && <div className="mt-3">{children}</div>}
    </section>
  );
}

/** Reopening, with the sentence that stops it reading as an undo. */
export function ReopenButton({ closureId }: { closureId: string }) {
  const [state, action] = useFormState<PlainState, FormData>(reopen, null);
  return (
    <div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <form action={action}>
        <input type="hidden" name="closure_id" value={closureId} />
        <Go label="Reopen" busy="Reopening…" quiet />
      </form>
    </div>
  );
}
