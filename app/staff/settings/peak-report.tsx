import { SectionLabel } from "@/components/ui";

export type Report = {
  days: number;
  peak_classes: number; classes: number; peak_share_pct: number | null;
  holders: number;
  periods_used: number; periods_exhausted: number; exhaustion_pct: number | null;
  reading: string;
  infractions: number; no_shows: number; excused: number;
  excused_pct: number | null; excuse_reading: string | null;
  suspended_now: number;
};

function Figure({ label, value, sub }: { label: string; value: React.ReactNode; sub?: string }) {
  return (
    <div>
      <div className="num text-[20px] leading-7 text-ink">{value}</div>
      <div className="text-[12px] leading-4 text-ink-2">{label}</div>
      {sub && <div className="text-[11px] leading-4 text-ink-3">{sub}</div>}
    </div>
  );
}

/**
 * Decision 24's numbers, and the one that needs a sentence beside it.
 *
 * Exhaustion is the figure a studio will act on and it is ambiguous in a way a
 * percentage cannot express: very high means the cap is too tight and is turning
 * people away from classes that have seats in them; near zero means it is not
 * binding at all. Both readings come from SQL rather than being decided here —
 * a threshold in a component is a second definition of the same judgement.
 */
export default function PeakReport({ r }: { r: Report }) {
  return (
    <section className="mb-10">
      <SectionLabel>How the limits are landing — last {r.days} days</SectionLabel>

      <div className="mt-3 grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-4">
        <Figure label="of your classes are peak"
                value={r.peak_share_pct === null ? "—" : `${r.peak_share_pct}%`}
                sub={`${r.peak_classes} of ${r.classes}`} />
        <Figure label="on a limited plan" value={r.holders} />
        <Figure label="of periods used up"
                value={r.exhaustion_pct === null ? "—" : `${r.exhaustion_pct}%`}
                sub={r.periods_used > 0 ? `${r.periods_exhausted} of ${r.periods_used}` : "nothing spent yet"} />
        <Figure label="suspended right now" value={r.suspended_now} />
      </div>

      <p className="mt-3 max-w-[64ch] rounded bg-paper px-3 py-2 text-[13px] leading-[19px] text-ink">
        {r.reading}
      </p>

      <div className="mt-5 grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-4">
        <Figure label="late cancellations and no-shows" value={r.infractions} />
        <Figure label="were no-shows" value={r.no_shows} />
        <Figure label="excused by staff"
                value={r.excused_pct === null ? r.excused : `${r.excused_pct}%`}
                sub={r.infractions > 0 ? `${r.excused} of ${r.infractions}` : undefined} />
      </div>

      {r.excuse_reading && (
        <p className="mt-3 max-w-[64ch] rounded border-l-2 border-coral bg-coral-tint px-3 py-2 text-[13px] leading-[19px] text-ink">
          {r.excuse_reading}
        </p>
      )}
    </section>
  );
}
