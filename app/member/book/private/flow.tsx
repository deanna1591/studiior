"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { accentSolid, accentChip } from "@/lib/accent-pair";
import { fmtClock } from "@/lib/clock";
import { groupGaps, privateReasonSentence } from "@/lib/private-sessions";
import { privateSlots } from "./actions";
import { startPrivate } from "../../account/plan/actions";

type T = { id: string; name: string; price_cents: number; people: number; duration_min: number; priceLabel: string };
type Coach = { id: string; name: string };

const DAYS = 14;

/** The studio-local midnight of day offset d, as an instant (UTC ms). */
function localMidnight(timeZone: string, d: number): Date {
  const now = new Date();
  const ymd = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
  const [y, m, day] = ymd.split("-").map(Number);
  // a guess at UTC midnight, corrected by the zone's offset at that instant
  const guess = Date.UTC(y, m - 1, day + d, 0, 0, 0);
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, hour12: false, year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(guess));
  const g = (k: string) => Number(parts.find((p) => p.type === k)?.value);
  const asLocal = Date.UTC(g("year"), g("month") - 1, g("day"), g("hour") % 24, g("minute"));
  return new Date(guess - (asLocal - guess));
}

export default function PrivateFlow({
  types, coaches, timeZone, timeFormat, packCredits, creditCents,
}: {
  types: T[]; coaches: Coach[]; timeZone: string; timeFormat: "24h" | "12h";
  packCredits: number; creditCents: number;
}) {
  const [typeId, setTypeId] = useState<string>(types[0]?.id ?? "");
  const [coachId, setCoachId] = useState<string | null>(null);
  const [day, setDay] = useState(0);
  const [starts, setStarts] = useState<string[]>([]);
  const [loading, startLoad] = useTransition();
  const [chosen, setChosen] = useState<string | null>(null);
  const [comps, setComps] = useState<{ name: string; email: string }[]>([]);
  const [pending, startPay] = useTransition();
  const [err, setErr] = useState<string | null>(null);

  const t = types.find((x) => x.id === typeId) ?? types[0];
  const need = (t?.people ?? 1) - 1;
  useEffect(() => { setComps(Array.from({ length: need }, (_, i) => comps[i] ?? { name: "", email: "" })); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [need]);

  useEffect(() => {
    if (!t) return;
    setChosen(null);
    startLoad(async () => {
      const from = localMidnight(timeZone, day), to = localMidnight(timeZone, day + 1);
      const r = await privateSlots(t.id, coachId, from.toISOString(), to.toISOString());
      setStarts(r.starts);
    });
  }, [t, coachId, day, timeZone]);

  const gaps = useMemo(() => groupGaps(starts), [starts]);
  const dayLabels = useMemo(() => Array.from({ length: DAYS }, (_, d) => {
    const at = localMidnight(timeZone, d);
    const f = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("en-GB", { timeZone, ...o }).format(new Date(at.getTime() + 12 * 3600e3));
    return { wd: f({ weekday: "short" }), dd: f({ day: "numeric" }) };
  }), [timeZone]);

  const usePack = t?.people === 1 && packCredits > 0;
  const creditCovers = !!t && creditCents >= t.price_cents;
  const compsOk = comps.every((c) => c.name.trim() && /.+@.+\..+/.test(c.email.trim()));

  function pay(mode: "xendit" | "pack") {
    if (!t || !chosen) return;
    setErr(null);
    startPay(async () => {
      const r = await startPrivate({ typeId: t.id, coachId, startsAt: chosen, companions: comps, payMode: mode });
      if (r.ok && r.url) { window.location.assign(r.url); return; }
      setErr(r.reason ? privateReasonSentence(r.reason) : (r.message ?? "That didn't work. Please try again."));
    });
  }

  const chip = (on: boolean) => on ? accentSolid() : { background: "var(--surface)", color: "var(--ink)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" };

  return (
    <div className="space-y-5">
      <section>
        <p className="m-label mb-2 text-ink">Session</p>
        <div className="space-y-2">
          {types.map((x) => (
            <button key={x.id} type="button" onClick={() => setTypeId(x.id)}
              className="m-card m-press flex w-full items-center justify-between px-4 py-3 text-left"
              style={x.id === typeId ? { boxShadow: "inset 0 0 0 2px var(--lime-text)" } : undefined}>
              <span>
                <span className="m-body block font-semibold text-ink">{x.name}</span>
                <span className="m-sub text-ink-2">{x.people === 1 ? "Just you" : `You and ${x.people - 1} ${x.people === 2 ? "friend" : "friends"}`} · {x.duration_min} min</span>
              </span>
              <span className="m-body font-semibold text-ink">{x.priceLabel}</span>
            </button>
          ))}
        </div>
      </section>

      <section>
        <p className="m-label mb-2 text-ink">Coach</p>
        <div className="flex flex-wrap gap-2">
          <button type="button" onClick={() => setCoachId(null)} className="m-press rounded-full px-4 py-2 text-[14px] font-semibold" style={chip(coachId === null)}>Any coach</button>
          {coaches.map((c) => (
            <button key={c.id} type="button" onClick={() => setCoachId(c.id)} className="m-press rounded-full px-4 py-2 text-[14px] font-semibold" style={chip(coachId === c.id)}>{c.name}</button>
          ))}
        </div>
      </section>

      <section>
        <p className="m-label mb-2 text-ink">Day</p>
        <div className="-mx-1 flex gap-1.5 overflow-x-auto px-1 pb-1">
          {dayLabels.map((l, d) => (
            <button key={d} type="button" onClick={() => setDay(d)}
              className="m-press flex w-12 shrink-0 flex-col items-center rounded-2xl py-2"
              style={chip(d === day)}>
              <span className="text-[11px] font-semibold">{l.wd}</span>
              <span className="text-[16px] font-bold">{l.dd}</span>
            </button>
          ))}
        </div>
      </section>

      <section>
        <p className="m-label mb-2 text-ink">Free times</p>
        {loading ? (
          <p className="m-sub text-ink-2">Looking for free times…</p>
        ) : gaps.length === 0 ? (
          <p className="m-sub text-ink-2">No free times this day. Try another day or any coach.</p>
        ) : (
          <div className="space-y-3">
            {gaps.map((g) => (
              <div key={g.from} className="m-card px-3 py-3">
                <p className="m-micro mb-2 text-ink-2">
                  Free {fmtClock(g.from, timeZone, timeFormat)} to {fmtClock(new Date(new Date(g.to).getTime() + (t?.duration_min ?? 50) * 60000).toISOString(), timeZone, timeFormat)}
                </p>
                <div className="flex flex-wrap gap-2">
                  {g.starts.map((s) => (
                    <button key={s} type="button" onClick={() => setChosen(s)}
                      className="m-press rounded-full px-3.5 py-1.5 text-[14px] font-semibold"
                      style={chosen === s ? accentSolid() : accentChip()}>
                      {fmtClock(s, timeZone, timeFormat)}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </section>

      {need > 0 && (
        <section>
          <p className="m-label mb-1 text-ink">Who&apos;s joining you</p>
          <p className="m-micro mb-2 text-ink-2">
            We email each of them a link to set up an account and sign the studio waiver before the session.
          </p>
          <div className="space-y-2">
            {comps.map((c, i) => (
              <div key={i} className="grid grid-cols-2 gap-2">
                <input value={c.name} onChange={(e) => setComps(comps.map((x, j) => j === i ? { ...x, name: e.target.value } : x))}
                  placeholder="Name" className="rounded-xl border border-line bg-surface px-3 py-2.5 text-[15px] text-ink" />
                <input value={c.email} type="email" onChange={(e) => setComps(comps.map((x, j) => j === i ? { ...x, email: e.target.value } : x))}
                  placeholder="Email" className="rounded-xl border border-line bg-surface px-3 py-2.5 text-[15px] text-ink" />
              </div>
            ))}
          </div>
        </section>
      )}

      {err && (
        <p className="rounded-lg px-3 py-2 text-[13px] leading-[19px]" style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{err}</p>
      )}

      <div className="space-y-2">
        {usePack && (
          <button type="button" disabled={pending || !chosen || !compsOk} onClick={() => pay("pack")}
            className="m-press w-full rounded-full py-3.5 text-[16px] font-semibold disabled:opacity-60" style={accentSolid()}>
            {pending ? "Booking…" : `Use a pack credit (${packCredits} left)`}
          </button>
        )}
        <button type="button" disabled={pending || !chosen || !compsOk} onClick={() => pay("xendit")}
          className="m-press w-full rounded-full py-3.5 text-[16px] font-semibold disabled:opacity-60"
          style={usePack ? { background: "var(--surface)", color: "var(--ink)", boxShadow: "inset 0 0 0 1.5px var(--ink)" } : accentSolid()}>
          {pending ? "Opening checkout…" : creditCovers ? `Book with your account credit` : `Pay ${t?.priceLabel ?? ""} and book`}
        </button>
        <p className="m-micro text-center text-ink-2">
          {creditCovers ? "Your account credit covers it, so there's nothing to pay." : "Card or GCash, on the next screen."}
        </p>
      </div>
    </div>
  );
}
