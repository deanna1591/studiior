"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { cancelOccurrencesForPeriod } from "@/app/staff/schedule/actions";

/**
 * Decision 47 — cancel this class, or the rest of its studio-local weekday this
 * month, from the roster header. Goes through cancel_occurrences_for_period →
 * cancel_occurrence, so booked members get the §3.2 treatment and the
 * instructor, if any, is told.
 */
export default function CancelClass({
  occurrenceId, weekday, hasInstructor, bookedCount,
}: {
  occurrenceId: string; weekday: string; hasInstructor: boolean; bookedCount: number;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [cause, setCause] = useState<"no_instructor" | "studio_fault" | "force_majeure">(
    hasInstructor ? "studio_fault" : "no_instructor");
  const [reason, setReason] = useState("");
  const [scope, setScope] = useState<"one" | "month">("one");
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const wd = weekday ? `${weekday}s` : "this weekday";

  const go = () => {
    const fd = new FormData();
    fd.set("occurrence_id", occurrenceId);
    fd.set("scope", scope);
    fd.set("cause", cause);
    if (reason.trim()) fd.set("reason", reason.trim());
    setMsg(null);
    start(async () => {
      const r = await cancelOccurrencesForPeriod(null, fd);
      if (r?.ok) { setMsg(r.message); start(() => router.refresh()); }
      else setMsg(r?.message ?? "That could not be done.");
    });
  };

  if (!open) {
    return (
      <div className="mb-5">
        <button type="button" onClick={() => setOpen(true)}
                className="text-[13px] text-coral-deep underline underline-offset-4 hover:opacity-80">
          Cancel this class
        </button>
      </div>
    );
  }

  return (
    <div className="mb-5 rounded-xl border border-line bg-surface p-3">
      <p className="text-[13px] font-medium text-ink">Why is it cancelled?</p>
      <div className="mt-1.5 flex flex-col gap-1">
        <label className="flex items-center gap-1.5 text-[13px] text-ink">
          <input type="radio" name="rcause" checked={cause === "no_instructor"}
                 onChange={() => setCause("no_instructor")} disabled={hasInstructor} />
          No instructor available{hasInstructor ? " (this class has one)" : ""}
        </label>
        <label className="flex items-center gap-1.5 text-[13px] text-ink">
          <input type="radio" name="rcause" checked={cause === "studio_fault"}
                 onChange={() => setCause("studio_fault")} />
          Studio&rsquo;s own reason
        </label>
        <label className="flex items-center gap-1.5 text-[13px] text-ink">
          <input type="radio" name="rcause" checked={cause === "force_majeure"}
                 onChange={() => setCause("force_majeure")} />
          Beyond anyone&rsquo;s control
        </label>
      </div>
      <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Add a note (optional)"
             className="mt-2 w-full rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink" />
      <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1.5">
        <label className="flex items-center gap-1.5 text-[13px] text-ink">
          <input type="radio" name="rscope" checked={scope === "one"} onChange={() => setScope("one")} />
          Just this class
        </label>
        <label className="flex items-center gap-1.5 text-[13px] text-ink">
          <input type="radio" name="rscope" checked={scope === "month"} onChange={() => setScope("month")} />
          Every {weekday || "week"} this month
        </label>
      </div>
      {bookedCount > 0 && (
        <p className="mt-2 text-[12.5px] leading-[18px] text-ink-2">
          {bookedCount} {bookedCount === 1 ? "member is" : "members are"} booked
          {scope === "month" ? ` across these ${wd}` : ""} — they&rsquo;ll get their credit back and an email.
        </p>
      )}
      {msg && <p className="mt-2 text-[13px] leading-[19px] text-ink-2">{msg}</p>}
      <div className="mt-2 flex items-center gap-2">
        <button onClick={go} disabled={pending}
                className="rounded-lg border bg-coral-tint px-3 py-1.5 text-[13px] font-medium text-ink disabled:opacity-60"
                style={{ borderColor: "var(--coral)" }}>
          {pending ? "…" : scope === "month" ? `Cancel these ${wd}` : "Cancel this class"}
        </button>
        <button type="button" onClick={() => { setOpen(false); setReason(""); }}
                className="text-[12.5px] text-ink-3 hover:text-ink">Keep it</button>
      </div>
    </div>
  );
}
