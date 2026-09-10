import Link from "next/link";
import type { MonthBlock } from "@/lib/dashboard";
import { Block, BlockEmpty } from "./block";

/**
 * 4.10. A month at a glance.
 *
 * The Bible marks classes, workshops, events, staff leave, maintenance,
 * launches, marketing campaigns and challenge deadlines. SIX OF THOSE EIGHT DO
 * NOT EXIST IN THIS PRODUCT. What does: classes, and studio closures from
 * migration 074 — which is staff leave and maintenance under the one name the
 * schema actually has for them. A legend with six permanently empty entries is
 * the same mistake as a revenue chart carrying a retail row.
 */
export default function MonthSnapshot({
  m, weekStartsOn, error,
}: { m: MonthBlock | null; weekStartsOn: number; error?: string | null }) {
  if (!m) return <Block title="This month" error={error}>{null}</Block>;

  const first = new Date(`${m.month}T00:00:00Z`);
  const lead = (first.getUTCDay() - weekStartsOn + 7) % 7;
  const label = new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC", month: "long", year: "numeric",
  }).format(first);
  // date_trunc('week') always means Monday; a studio whose week starts on
  // Sunday has to be asked about the right seven days, which is what
  // studio_settings.week_starts_on has been for since migration 001.
  const dowNames = Array.from({ length: 7 }, (_, i) =>
    ["S", "M", "T", "W", "T", "F", "S"][(weekStartsOn + i) % 7]);
  const max = Math.max(1, ...m.days.map((d) => d.classes));

  return (
    <Block
      title="This month"
      hint={m.state === "ok" ? `${m.total_classes} classes in ${label}` : label}
      right={
        <Link href="/schedule" className="text-[12px] leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2">
          Schedule
        </Link>
      }
      error={error}
    >
      {m.state === "empty" ? (
        <BlockEmpty cta={{ href: "/series", label: "Set up a recurring class" }}>
          {m.empty_hint}
        </BlockEmpty>
      ) : (
        <>
          <div className="grid grid-cols-7 gap-1">
            {dowNames.map((d, i) => (
              <div key={i} className="pb-1 text-center text-[10px] leading-4 text-ink-3">{d}</div>
            ))}
            {Array.from({ length: lead }, (_, i) => <div key={`lead${i}`} />)}
            {m.days.map((d) => {
              const n = Number(d.date.slice(8, 10));
              const strength = d.classes === 0 ? 0 : Math.max(18, (d.classes / max) * 100);
              return (
                <Link
                  key={d.date}
                  href={`/schedule?d=${d.date}`}
                  title={
                    d.closed
                      ? `${d.date} — closed${d.closure_reason ? `: ${d.closure_reason}` : ""}`
                      : `${d.date} — ${d.classes} ${d.classes === 1 ? "class" : "classes"}`
                  }
                  className={`relative flex h-9 items-center justify-center rounded text-[12px] leading-4 ${
                    d.is_today ? "outline outline-[1.5px] outline-ink" : ""
                  } ${d.closed ? "hatched border border-line-2" : ""}`}
                  style={
                    d.closed
                      ? undefined
                      : { background: `color-mix(in srgb, var(--lime) ${strength}%, var(--surface))` }
                  }
                >
                  <span className={`num ${d.classes === 0 && !d.closed ? "text-ink-3" : "text-ink"}`}>
                    {n}
                  </span>
                </Link>
              );
            })}
          </div>
          <p className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] leading-4 text-ink-3">
            <span className="flex items-center gap-1.5">
              <span className="inline-block h-3 w-3 rounded-sm border border-line-2"
                    style={{ background: "color-mix(in srgb, var(--lime) 70%, var(--surface))" }} />
              busier
            </span>
            <span className="flex items-center gap-1.5">
              <span className="hatched inline-block h-3 w-3 rounded-sm border border-line-2" />
              closed
            </span>
          </p>
        </>
      )}
    </Block>
  );
}
