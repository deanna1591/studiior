import Link from "next/link";
import { money, type AbsentCard, type Kpi, type Trend } from "@/lib/dashboard";

function figure(c: Kpi): string {
  if (c.value === null) return "—";
  if (c.kind === "money") return money(c.value, c.currency ?? "GBP");
  if (c.kind === "percent") return `${c.value}%`;
  return new Intl.NumberFormat("en-GB").format(c.value);
}

/**
 * The change, in the form that says something.
 *
 * A percentage only where the prior period was big enough to divide by —
 * migration 091 nulls it below the floor, and three bookings becoming
 * thirty-five then reads "+32" instead of "↑ 1067%", which is arithmetically
 * true and reads as a broken widget. The Bible's own bookings card shows a
 * count and its revenue card a percentage, for the same reason.
 */
function TrendLine({ t, kind, currency }: { t: Trend; kind: Kpi["kind"]; currency?: string }) {
  const arrow = t.direction === "up" ? "↑" : t.direction === "down" ? "↓" : "";
  const shown =
    t.pct !== null
      ? `${Math.abs(t.pct)}%`
      : kind === "money"
        ? money(Math.abs(t.delta), currency ?? "GBP")
        : `${t.delta > 0 ? "+" : t.delta < 0 ? "−" : ""}${Math.abs(t.delta)}`;

  // Coral is 4.47 on white and never sets a sentence — but this is a numeral
  // at 12px semibold beside an arrow, which is the "large numerals" case the
  // palette rule allows it. Down is not automatically bad, so it carries the
  // colour and not a warning shape.
  const tone =
    t.direction === "flat" ? "text-ink-3"
      : t.direction === "up" ? "text-lime-text" : "text-coral-deep";

  return (
    <p className="mt-1.5 text-[11px] leading-4 text-ink-3">
      <span className={`num font-semibold ${tone}`}>
        {arrow} {shown}
      </span>{" "}
      {t.basis === "joined this month" ? t.basis : `on ${t.basis}`}
    </p>
  );
}

function Card({ c }: { c: Kpi }) {
  const amber = c.tone === "amber" && c.state === "ok";
  return (
    <Link
      href={c.href}
      className={`panel group block p-4 transition hover:shadow-[0_2px_4px_rgb(20_23_14_/_0.06),0_14px_34px_-14px_rgb(20_23_14_/_0.18)] ${
        amber ? "border-edge-amber bg-amber-tint" : ""
      }`}
    >
      <p className="text-[11px] font-medium uppercase leading-4 tracking-[0.06em] text-ink-2">
        {c.label}
      </p>

      {c.state === "empty" ? (
        <>
          {/* Not a zero. A studio that has never taken a payment has not had a
              bad day — it has not started yet, and saying "0" tells it the
              wrong thing on the one morning it most needs telling the right
              one. */}
          <p className="kpi-figure kpi-figure-sm mt-2 text-ink-3">—</p>
          <p className="mt-1.5 max-w-[34ch] text-[11px] leading-[15px] text-ink-3">
            {c.empty_hint}
          </p>
        </>
      ) : (
        <>
          <p className="kpi-figure mt-2">{figure(c)}</p>
          {c.sub && <p className="mt-1 text-[11px] leading-4 text-ink-2">{c.sub}</p>}
          {c.trend ? (
            <TrendLine t={c.trend} kind={c.kind} currency={c.currency} />
          ) : (
            !c.sub && <p className="mt-1.5 h-4" aria-hidden />
          )}
        </>
      )}
    </Link>
  );
}

export default function KpiCards({
  cards, absent, error,
}: {
  cards: Kpi[];
  absent: AbsentCard[];
  error?: string | null;
}) {
  if (error) {
    return (
      <div className="rounded-lg border-l-[3px] border-coral bg-coral-tint px-3 py-2.5">
        <p className="text-[13px] leading-[19px] text-ink">
          Your figures could not be read. This is not an empty studio.
        </p>
        <p className="num mt-1.5 text-[11px] leading-4 text-ink-2">{error}</p>
      </div>
    );
  }
  return (
    <>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {cards.map((c) => <Card key={c.key} c={c} />)}
      </div>

      {/* THE CARDS THAT ARE NOT HERE. The Bible specifies eight; a card that
          can never populate is the insight-without-a-button mistake, and one
          quietly missing is how it gets rediscovered as a bug in six months.
          One line, under the row, rather than a card pretending. */}
      {absent.length > 0 && (
        <p className="mt-3 max-w-[80ch] text-[11px] leading-[16px] text-ink-3">
          <span className="font-medium text-ink-2">Not shown:</span>{" "}
          {absent.map((a, i) => (
            <span key={a.key}>
              {i > 0 && " "}
              <span className="text-ink-2">{a.label}</span> — {a.why}
            </span>
          ))}
        </p>
      )}
    </>
  );
}
