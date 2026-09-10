import Link from "next/link";
import { money, type RevenueBlock } from "@/lib/dashboard";
import { Block, BlockEmpty, Narrative } from "./block";

const WINDOWS = [7, 30, 90, 365];

/**
 * 4.4. Revenue by day and by source.
 *
 * RETAIL AND GIFT CARDS ARE OMITTED, not zeroed. They are not in this product
 * — promo_code_id and gift_card_id have been columns on `payments` since
 * migration 001 with nothing writing them — and a legend carrying two
 * permanent noughts teaches an owner that this chart has categories it does
 * not fill in. The Bible's own example splits four ways including retail at
 * 15%; where it and this product disagree, the product wins and says so.
 *
 * Drawn as SVG rather than pulled from a chart library: it is forty-odd rects
 * and a baseline, it renders on the server with no hydration, and it inherits
 * the palette instead of bringing its own.
 */
export default function RevenueWidget({
  r, days, narrative, error, hrefFor,
}: {
  r: RevenueBlock | null;
  days: number;
  narrative: string | null | undefined;
  error?: string | null;
  hrefFor: (d: number) => string;
}) {
  const switcher = (
    <div className="flex items-center gap-1">
      {WINDOWS.map((d) => (
        <Link
          key={d}
          href={hrefFor(d)}
          className={`num rounded px-2 py-1 text-[11px] leading-4 ${
            d === days
              ? "bg-ink text-paper"
              : "border border-line-2 bg-surface text-ink-2 hover:text-ink"
          }`}
        >
          {d === 365 ? "1y" : `${d}d`}
        </Link>
      ))}
    </div>
  );

  return (
    <Block title="Revenue" right={switcher} error={error}>
      {!r ? null : r.state === "empty" ? (
        <BlockEmpty cta={{ href: "/members", label: "Record a payment" }}>
          {r.empty_hint}
        </BlockEmpty>
      ) : (
        <>
          <Narrative text={narrative} />

          <div className="flex flex-wrap items-baseline gap-x-5 gap-y-1">
            <span className="kpi-figure">{money(r.total_cents, r.currency)}</span>
            <span className="text-[12px] leading-4 text-ink-3">
              over {r.days} days
              {r.counts.refunds_cents > 0 && (
                // Beside revenue, never netted off it. A studio that took
                // 2,000 and refunded 500 had both of those happen, and one
                // number hides one of them.
                <> · <span className="num text-coral-deep">
                  {money(r.counts.refunds_cents, r.currency)} refunded
                </span></>
              )}
            </span>
          </div>

          <Chart series={r.series} currency={r.currency} />

          <div className="mt-4 border-t border-line pt-3">
            <h3 className="section-label mb-2 text-ink-3">Where it came from</h3>
            <ul className="space-y-1.5">
              {r.by_source.map((s) => (
                <li key={s.source} className="flex items-center gap-3">
                  <span className="w-[112px] shrink-0 text-[12px] leading-4 text-ink-2">
                    {s.label}
                  </span>
                  <span className="h-2 flex-1 overflow-hidden rounded-full bg-line">
                    <span
                      className="block h-full rounded-full bg-lime"
                      style={{ width: `${Math.max(s.pct, 1)}%` }}
                    />
                  </span>
                  <span className="num w-9 shrink-0 text-right text-[12px] leading-4 text-ink-2">
                    {s.pct}%
                  </span>
                  <span className="num w-24 shrink-0 text-right text-[12px] leading-4 text-ink">
                    {money(s.cents, r.currency)}
                  </span>
                </li>
              ))}
            </ul>
          </div>

          <p className="mt-3 text-[11px] leading-4 text-ink-3">
            <span className="num">{r.counts.bookings}</span> bookings and{" "}
            <span className="num">{r.counts.memberships_sold}</span> memberships sold
            in the same period.
          </p>
        </>
      )}
    </Block>
  );
}

function Chart({ series, currency }: { series: { date: string; cents: number }[]; currency: string }) {
  const max = Math.max(1, ...series.map((d) => d.cents));
  const n = series.length;
  const W = 720, H = 120, gap = n > 120 ? 0 : 1;
  const bw = Math.max(1, W / n - gap);

  return (
    <div className="mt-3 overflow-x-auto">
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        className="h-[120px] w-full"
        role="img"
        aria-label={`Daily takings over ${n} days, highest ${money(max, currency)}`}
      >
        {/* Every day of the range has a bar, including the days with nothing:
            a chart that skips its empty days draws a slope where there was a
            gap. */}
        {series.map((d, i) => {
          const h = (d.cents / max) * (H - 8);
          return (
            <rect
              key={d.date}
              x={i * (bw + gap)}
              y={H - h}
              width={bw}
              height={Math.max(h, d.cents > 0 ? 2 : 0.75)}
              rx={bw > 3 ? 1.5 : 0}
              fill={d.cents > 0 ? "var(--lime-text)" : "var(--line)"}
            />
          );
        })}
      </svg>
      <div className="mt-1 flex justify-between text-[10px] leading-4 text-ink-3">
        <span className="num">{series[0]?.date}</span>
        <span className="num">{series[series.length - 1]?.date}</span>
      </div>
    </div>
  );
}
