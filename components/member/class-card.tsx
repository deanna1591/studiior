import Link from "next/link";

/**
 * One class, as a card on the washed page.
 *
 * THE SHAPE IS HORIZONTAL, not stacked. The old card put the time, then the
 * name, then the instructor, then a divider, then the action — five bands down
 * a card, which is a paragraph with a button under it. This one reads left to
 * right: a colour stripe, the time, what it is, and the one thing you can do.
 * Six of them down a screen scan as a timetable rather than as six documents.
 *
 * THE STRIPE is the accent, and it is also the status. Booked adds a ring; a
 * class that has gone or filled takes --line-2 instead, so a member can tell
 * the dead rows from the live ones from the left edge alone, before reading a
 * word.
 *
 * THE TYPE RATIO does the rest: the time is 16px Archivo bold against 11.5px
 * metadata. Everything used to sit between 12 and 15px.
 *
 * Two targets in one card, which HTML will not nest — a form inside an anchor
 * is invalid. The link is an overlay; the action sits above it on its own
 * layer.
 */
export default function ClassCard({
  href, startLabel, endLabel, durationLabel, name, instructor, room,
  statusLabel, statusTone = "quiet", action, dimmed = false, booked = false,
}: {
  href: string;
  /** "06:30" — the start alone, in the studio's zone. */
  startLabel: string;
  /** "07:20" — the end, set small beneath it. The mockup puts AM/PM here;
      fmtTime is a 24-hour clock, so there is no meridiem to set, and the end
      of the class is the thing a member actually wants in that space. */
  endLabel: string | null;
  durationLabel: string;
  name: string;
  instructor: string | null;
  room: string | null;
  statusLabel: React.ReactNode;
  statusTone?: "quiet" | "booked" | "full" | "holding";
  action: React.ReactNode;
  dimmed?: boolean;
  booked?: boolean;
}) {
  const muted = dimmed || statusTone === "full";
  return (
    <li className={`m-card relative flex items-stretch gap-3 py-4 pl-4 pr-4 ${booked ? "m-card-booked" : ""} ${dimmed ? "opacity-90" : ""}`}>
      <Link href={href} className="absolute inset-0 rounded-[22px]" aria-label={`Open ${name}`}>
        <span className="sr-only">Open {name}</span>
      </Link>

      <span aria-hidden className={`m-stripe ${muted ? "m-stripe-muted" : ""}`} />

      {/* A fixed column, so six cards line their times up on one edge. Ragged
          times are what made the old list read as prose. */}
      <div className="pointer-events-none w-[56px] shrink-0 pt-0.5">
        <p className="num m-time-lg text-ink">{startLabel}</p>
        {endLabel && <p className="num m-dur mt-0.5 text-ink-3">{endLabel}</p>}
      </div>

      <div className="pointer-events-none min-w-0 flex-1">
        <p className={`m-name truncate ${muted ? "text-ink-3" : "text-ink"}`}>{name}</p>
        <p className="m-subtle mt-0.5 truncate text-ink-3">
          {/* Absent, not "TBC". Decision 17: an open shift reads as a normal
              class to a member, and a row saying nobody has agreed to teach it
              is a doubt they can do nothing with. */}
          {[instructor, room].filter(Boolean).join(" · ")}
        </p>
        <p className="m-subtle mt-1.5">
          {/* Duration and seats on one line, in one weight, with the status
              carrying the only colour. An icon chip belongs on a stat, where
              it is the only thing distinguishing three identical numbers —
              here it would be a third mark competing with the stripe. */}
          <span className="text-ink-3">{durationLabel} · </span>
          <span
            className={statusTone === "quiet" ? "text-ink-3" : "font-semibold"}
            style={
              statusTone === "booked"  ? { color: "var(--lime-text)" }
              : statusTone === "holding" ? { color: "var(--amber-deep)" }
              : statusTone === "full"    ? { color: "var(--ink-3)" }
              : undefined
            }
          >
            {statusLabel}
          </span>
        </p>
      </div>

      <div className="pointer-events-auto flex shrink-0 items-center">{action}</div>
    </li>
  );
}
