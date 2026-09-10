import Link from "next/link";
import type { HeatmapBlock } from "@/lib/dashboard";
import { Block, BlockEmpty, Narrative } from "./block";

const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const DOW_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/**
 * 4.5. Day by hour, in the STUDIO's clock.
 *
 * The hours drawn are the hours the studio uses, floored an hour either side —
 * 06:00 to 22:00 was a guess about somebody else's studio, and the local seed
 * switched to Manila has a class at midnight that such a window cannot draw at
 * all. Same rule the calendar already follows.
 */
export default function Heatmap({
  h, narrative, error,
}: {
  h: HeatmapBlock | null;
  narrative: string | null | undefined;
  error?: string | null;
}) {
  if (!h || h.state === "empty") {
    return (
      <Block title="When your week fills" error={error}>
        {h && (
          <BlockEmpty cta={{ href: "/series", label: "Set up your timetable" }}>
            {h.empty_hint}
          </BlockEmpty>
        )}
      </Block>
    );
  }

  const hours = h.cells.map((c) => c.hour);
  const lo = Math.max(0, Math.min(...hours) - 1);
  const hi = Math.min(23, Math.max(...hours) + 1);
  const rows = Array.from({ length: hi - lo + 1 }, (_, i) => lo + i);
  const at = new Map(h.cells.map((c) => [`${c.dow}:${c.hour}`, c]));

  return (
    <Block
      title="When your week fills"
      hint={`Last ${h.days} days, in ${h.timezone.replace("_", " ")}`}
      error={error}
    >
      <Narrative text={narrative} />

      <div className="overflow-x-auto">
        <table className="w-full min-w-[420px] border-separate border-spacing-[3px]">
          <thead>
            <tr>
              <th className="w-10" />
              {DOW.map((d, i) => (
                <th key={i} className="pb-1 text-[11px] font-medium leading-4 text-ink-2">{d}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((hr) => (
              <tr key={hr}>
                <td className="num pr-1 text-right align-middle text-[10px] leading-4 text-ink-3">
                  {String(hr).padStart(2, "0")}
                </td>
                {DOW.map((_, dow) => {
                  const c = at.get(`${dow}:${hr}`);
                  const occ = c?.occupancy ?? null;
                  return (
                    <td key={dow} className="p-0">
                      <div
                        className="hm-cell h-6"
                        title={
                          c
                            ? `${DOW_LONG[dow]} ${String(hr).padStart(2, "0")}:00 — ${occ}% full, ${c.classes} ${c.classes === 1 ? "class" : "classes"}`
                            : `${DOW_LONG[dow]} ${String(hr).padStart(2, "0")}:00 — nothing on`
                        }
                        style={{
                          // The value is carried by the fill's opacity over the
                          // studio-neutral lime, floored at 12% so a cell with
                          // a class in it never disappears into an empty one.
                          // AN ABSOLUTE SCALE, not one normalised to the
                          // busiest cell. Relative shading would paint a
                          // studio running everything at 30% exactly like one
                          // running everything at 90% — the map would look
                          // identical and mean the opposite. So the legend
                          // below says what the colour is worth, and the floor
                          // at 18 only keeps a cell with a class in it from
                          // vanishing into an empty one.
                          background: c
                            ? `color-mix(in srgb, var(--lime) ${Math.max(18, occ ?? 0)}%, var(--surface))`
                            : "var(--paper)",
                        }}
                      />
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] leading-4 text-ink-3">
        <span className="flex items-center gap-1.5">
          <span className="hm-cell inline-block h-3 w-3" style={{ background: "var(--paper)" }} />
          nothing on
        </span>
        <span className="flex items-center gap-1">
          {[18, 40, 70, 100].map((v) => (
            <span key={v} className="hm-cell inline-block h-3 w-3"
                  style={{ background: `color-mix(in srgb, var(--lime) ${v}%, var(--surface))` }} />
          ))}
          <span className="ml-1">emptier → fuller</span>
        </span>
      </div>

      {/* THE SUGGESTION THE BIBLE ASKS FOR, and it has a working button.
          An insight without one is a bug, not a feature — so this links to the
          series form rather than offering a "Duplicate" that goes nowhere. */}
      {h.peak && (
        <div className="mt-4 rounded-lg border border-line bg-paper px-3 py-2.5">
          <p className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">
              {DOW_LONG[h.peak.dow]} at {String(h.peak.hour).padStart(2, "0")}:00
            </span>{" "}
            is your fullest slot — <span className="num">{h.peak.occupancy}%</span> across{" "}
            <span className="num">{h.peak.classes}</span> classes.
          </p>
          <Link
            href="/series/new"
            className="mt-1.5 inline-block text-[12px] font-medium leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2"
          >
            Add another class there
          </Link>
          <p className="mt-2 text-[11px] leading-4 text-ink-3">
            Counted only where at least {h.min_classes_for_pattern} classes have run
            in a slot — one busy Thursday is not a pattern.
          </p>
        </div>
      )}
    </Block>
  );
}
