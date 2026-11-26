"use client";

import { PriceAmount, PromoTagChip } from "@/components/price-tag";
import type { PlanPrice } from "@/lib/promo";
import Link from "next/link";
import { useEffect, useMemo, useState, useTransition } from "react";
import { accentSolid, accentChip } from "@/lib/accent-pair";
import { fmtClock } from "@/lib/clock";
import { certificationLines, coachAvatarRow, coachStep, groupGaps, privateReasonSentence, REPLACES_LABEL, slotReplaces, slotsForCoach, type Slot } from "@/lib/private-sessions";
import Avatar from "@/components/member/avatar";
import { privateSlots } from "./actions";
import { startPrivate } from "../../account/plan/actions";
import CodeBox from "@/components/code-box";
import { previewMemberCode } from "@/app/member/code-actions";
import { formatMoney } from "@/lib/format-money";
import type { CodePreview } from "@/lib/discount-code";

type T = { id: string; name: string; price_cents: number; people: number; duration_min: number; priceLabel: string };
type Coach = { id: string; name: string; displayName?: string; avatarUrl?: string | null; bio?: string | null; certifications?: string[] };

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
  types, coaches, timeZone, timeFormat, packCredits, creditCents, packs = [], initialTypeId = null,
}: {
  /** Decision 119(a): the rescue email's link opens on the session type. */
  initialTypeId?: string | null;
  types: T[]; coaches: Coach[]; timeZone: string; timeFormat: "24h" | "12h";
  /** Decision 116(d): pack credits held, keyed by session type id. */
  packCredits: Record<string, number>; creditCents: number;
  /** Decision 117: the private packs priced now (a sale shows its tag). */
  packs?: { id: string; name: string; price_cents: number; list_cents: number; currency: string; promo: PlanPrice | null; typeId: string | null }[];
}) {
  const [typeId, setTypeId] = useState<string>(
    (initialTypeId && types.some((x) => x.id === initialTypeId) ? initialTypeId : types[0]?.id) ?? "");
  // Decision 116(b): the coach filter (null = all coaches) and the coach the
  // chosen time is with. There is no "any coach": a time names its coach.
  const [filter, setFilter] = useState<string | null>(null);
  const [coachId, setCoachId] = useState<string | null>(null);
  const [day, setDay] = useState(0);
  const [slots, setSlots] = useState<Slot[]>([]);
  const [loading, startLoad] = useTransition();
  const [chosen, setChosen] = useState<string | null>(null);
  const [comps, setComps] = useState<{ name: string; email: string }[]>([]);
  const [pending, startPay] = useTransition();
  // Decision 120: a code on the pay step (Xendit only).
  const [code, setCode] = useState<CodePreview | null>(null);
  const [err, setErr] = useState<string | null>(null);
  // Decision 116(c): the coach whose profile sheet is open.
  const [profileId, setProfileId] = useState<string | null>(null);

  const t = types.find((x) => x.id === typeId) ?? types[0];
  const need = (t?.people ?? 1) - 1;
  useEffect(() => { setComps(Array.from({ length: need }, (_, i) => comps[i] ?? { name: "", email: "" })); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [need]);

  useEffect(() => {
    if (!t) return;
    setChosen(null); setCoachId(null);
    startLoad(async () => {
      const from = localMidnight(timeZone, day), to = localMidnight(timeZone, day + 1);
      const r = await privateSlots(t.id, null, from.toISOString(), to.toISOString());
      setSlots(r.slots);
    });
  }, [t, day, timeZone]);

  const visible = useMemo(() => slotsForCoach(slots, filter), [slots, filter]);
  const byStart = useMemo(() => new Map(visible.map((s) => [s.start, s])), [visible]);
  const gaps = useMemo(() => groupGaps(visible.map((s) => s.start)), [visible]);
  const coachName = (id: string) => coaches.find((c) => c.id === id)?.name ?? "Coach";
  const chosenSlot = chosen ? byStart.get(chosen) ?? null : null;
  const step = coachStep(chosenSlot);
  function pick(s: string) {
    setChosen(s);
    const st = coachStep(byStart.get(s));
    setCoachId(st.skip ? st.coachId : null);
  }
  function pickFilter(id: string | null) {
    setFilter(id); setChosen(null); setCoachId(null);
  }
  const dayLabels = useMemo(() => Array.from({ length: DAYS }, (_, d) => {
    const at = localMidnight(timeZone, d);
    const f = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("en-GB", { timeZone, ...o }).format(new Date(at.getTime() + 12 * 3600e3));
    return { wd: f({ weekday: "short" }), dd: f({ day: "numeric" }) };
  }), [timeZone]);

  // Decision 116(d): a pack is spent only on its own session type.
  const typeCredits = t ? packCredits[t.id] ?? 0 : 0;
  const usePack = !!t && typeCredits > 0;
  const typePacks = t ? packs.filter((p) => p.typeId === t.id) : [];
  const creditCovers = !!t && creditCents >= t.price_cents;
  // Decision 120(a): a 100% code; the session completes with nothing to pay.
  const codeFree = code?.priceCents === 0;
  const compsOk = comps.every((c) => c.name.trim() && /.+@.+\..+/.test(c.email.trim()));

  function pay(mode: "xendit" | "pack") {
    if (!t || !chosen || !coachId) return;
    setErr(null);
    startPay(async () => {
      const r = await startPrivate({ typeId: t.id, coachId, startsAt: chosen, companions: comps, payMode: mode,
        code: mode === "xendit" ? code?.code ?? null : null });
      if (r.ok && r.url) { window.location.assign(r.url); return; }
      setErr(r.reason === "code" ? (r.message ?? "That code isn't valid.") : r.reason ? privateReasonSentence(r.reason) : (r.message ?? "That didn't work. Please try again."));
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
        {/* Decision 116(c): "Coaches", a row of round photos (initials when there
            is none) with the first name under each; "All" first. The photo
            filters the times; the name opens the coach's profile. */}
        <p className="m-micro mb-2 text-ink-2">Coaches</p>
        <div className="-mx-1 mb-3 flex gap-3 overflow-x-auto px-1 pb-1" data-testid="coach-filter">
          {coachAvatarRow(coaches.map((c) => ({ id: c.id, first_name: c.name, display_name: c.displayName ?? c.name, avatar_url: c.avatarUrl ?? null })), filter)
            .map((it) => (
              <div key={it.id ?? "all"} className="flex w-[64px] shrink-0 flex-col items-center gap-1">
                <button type="button" onClick={() => pickFilter(it.id)} aria-pressed={it.selected}
                  aria-label={it.id ? `Show ${it.label}'s times` : "Show every coach's times"}
                  className="m-press rounded-full p-[3px]"
                  style={{ boxShadow: it.selected ? "inset 0 0 0 2.5px var(--accent-solid)" : "none" }}>
                  {it.id === null ? (
                    <span className="flex h-[52px] w-[52px] items-center justify-center rounded-full border border-line text-[14px] font-semibold"
                      style={it.selected ? accentSolid() : { background: "var(--accent-chip)", color: "var(--ink)" }}>All</span>
                  ) : (
                    <Avatar name={coaches.find((c) => c.id === it.id)?.displayName ?? it.label} url={it.photo} size={52} />
                  )}
                </button>
                {it.id === null ? (
                  <span className="text-[12.5px] font-semibold text-ink">All</span>
                ) : (
                  <button type="button" onClick={() => setProfileId(it.id)}
                    className="max-w-full truncate text-[12.5px] font-semibold text-ink underline decoration-dotted underline-offset-4">
                    {it.label}
                  </button>
                )}
              </div>
            ))}
        </div>
        {loading ? (
          <p className="m-sub text-ink-2">Looking for free times…</p>
        ) : gaps.length === 0 ? (
          <p className="m-sub text-ink-2">{filter ? `No free times with ${coachName(filter)} this day. Try another day or all coaches.` : "No free times this day. Try another day."}</p>
        ) : (
          <div className="space-y-3">
            {gaps.map((g) => (
              <div key={g.from} className="m-card px-3 py-3">
                <p className="m-micro mb-2 text-ink-2">
                  Free {fmtClock(g.from, timeZone, timeFormat)} to {fmtClock(new Date(new Date(g.to).getTime() + (t?.duration_min ?? 50) * 60000).toISOString(), timeZone, timeFormat)}
                </p>
                <div className="flex flex-wrap gap-2">
                  {g.starts.map((s) => {
                    const sl = byStart.get(s);
                    // The time picks the slot; each coach name under it is its
                    // own tap target that opens that coach's profile (116(c)).
                    return (
                      <div key={s} className="rounded-2xl px-3.5 py-1.5 text-left"
                        style={chosen === s ? accentSolid() : accentChip()}>
                        <button type="button" onClick={() => pick(s)}
                          className="m-press block text-left text-[14px] font-semibold" style={{ color: "inherit" }}>
                          {fmtClock(s, timeZone, timeFormat)}
                          {slotReplaces(sl) && (
                            <span className="block text-[11.5px] font-medium">{REPLACES_LABEL}</span>
                          )}
                        </button>
                        <span className="block text-[12px] font-medium">
                          {(sl?.coaches ?? []).map((c, i) => (
                            <span key={c.id}>
                              {i > 0 && ", "}
                              <button type="button" onClick={() => setProfileId(c.id)}
                                className="underline decoration-dotted underline-offset-2" style={{ color: "inherit" }}>
                                {coachName(c.id)}
                              </button>
                            </span>
                          ))}
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        )}
      </section>

      {chosenSlot && !step.skip && (
        <section>
          <p className="m-label mb-2 text-ink">Coach</p>
          <div className="flex flex-wrap gap-2">
            {step.choices.map((id) => (
              <button key={id} type="button" onClick={() => setCoachId(id)}
                className="m-press rounded-full px-4 py-2 text-[14px] font-semibold" style={chip(coachId === id)}>{coachName(id)}</button>
            ))}
          </div>
        </section>
      )}

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

      {t && !creditCovers && (
        <div>
          <CodeBox key={t.id} name={null} currency={code?.currency ?? "PHP"} onChange={setCode}
                   preview={(c) => previewMemberCode({ code: c, privateTypeId: t.id })} />
        </div>
      )}

      <div className="space-y-2">
        {usePack && (
          <button type="button" disabled={pending || !chosen || !coachId || !compsOk} onClick={() => pay("pack")}
            className="m-press w-full rounded-full py-3.5 text-[16px] font-semibold disabled:opacity-60" style={accentSolid()}>
            {pending ? "Booking…" : `Use 1 of your ${typeCredits} ${t?.name ?? ""} session${typeCredits === 1 ? "" : "s"}`}
          </button>
        )}
        <button type="button" disabled={pending || !chosen || !coachId || !compsOk} onClick={() => pay("xendit")}
          className="m-press w-full rounded-full py-3.5 text-[16px] font-semibold disabled:opacity-60"
          style={usePack ? { background: "var(--surface)", color: "var(--ink)", boxShadow: "inset 0 0 0 1.5px var(--ink)" } : accentSolid()}>
          {pending ? (codeFree ? "Booking…" : "Opening checkout…") : codeFree ? "Complete" : creditCovers ? `Book with your account credit` : `Pay ${code?.priceCents != null ? formatMoney(code.priceCents, code.currency ?? "PHP") : t?.priceLabel ?? ""} and book`}
        </button>
        <p className="m-micro text-center text-ink-2">
          {codeFree ? `Total ${formatMoney(0, code?.currency ?? "PHP")}. Nothing to pay.` : creditCovers ? "Your account credit covers it, so there's nothing to pay." : "Card or GCash, on the next screen."}
        </p>
      </div>
      {/* Decision 117: private packs for this session type (116 d). A pack on sale shows the
          struck list price and its tag; the single session price never does. */}
      {typePacks.length > 0 && (
        <section>
          <h2 className="section-label mb-2 text-ink-2">Or buy a private pack</h2>
          <ul className="space-y-2">
            {typePacks.map((p) => (
              <li key={p.id}>
                <Link href={`/buy/${p.id}`} className="m-card m-press flex items-center justify-between gap-3 p-4">
                  <span className="min-w-0">
                    <span className="block text-[15px] font-semibold leading-5 text-ink">{p.name}</span>
                    {p.promo && <PromoTagChip promo={p.promo} className="mt-1" />}
                  </span>
                  <PriceAmount priceCents={p.price_cents} listCents={p.list_cents} currency={p.currency}
                               promo={p.promo} className="shrink-0 text-[15px] font-semibold text-ink" />
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}
      {profileId && (
        <CoachProfile coach={coaches.find((c) => c.id === profileId) ?? null} onClose={() => setProfileId(null)} />
      )}
    </div>
  );
}

/**
 * Decision 116(c): the coach's profile, sliding up over the slot list. Photo,
 * display name, the Bio and Certifications staff wrote. A coach with an empty
 * Bio still opens with photo and name.
 */
function CoachProfile({ coach, onClose }: { coach: Coach | null; onClose: () => void }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [onClose]);
  if (!coach) return null;
  const name = coach.displayName ?? coach.name;
  const certs = certificationLines(coach.certifications);
  return (
    <>
      <div className="m-sheet-scrim" onClick={onClose} aria-hidden />
      <div role="dialog" aria-modal="true" aria-label={name} className="m-sheet" data-testid="coach-profile">
        <div className="m-sheet-grab" aria-hidden />
        <div className="m-sheet-body px-5 pb-8 pt-2">
          <div className="flex items-center gap-4">
            <Avatar name={name} url={coach.avatarUrl ?? null} size={72} />
            <p className="m-title text-ink">{name}</p>
          </div>
          {coach.bio && <p className="m-body mt-4 whitespace-pre-line text-ink">{coach.bio}</p>}
          {certs.length > 0 && (
            <div className="mt-4">
              <p className="m-label mb-1 text-ink">Certifications</p>
              <ul className="space-y-0.5">
                {certs.map((c) => <li key={c} className="m-sub text-ink-2">{c}</li>)}
              </ul>
            </div>
          )}
          <button type="button" onClick={onClose}
            className="m-press mt-6 w-full rounded-full py-3 text-[15px] font-semibold" style={accentChip()}>Done</button>
        </div>
      </div>
    </>
  );
}
