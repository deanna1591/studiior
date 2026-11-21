import Link from "next/link";
import Avatar from "@/components/member/avatar";
import { FlexChip, type FlexChipInput } from "@/components/member/flex-chip";

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
  statusLabel, statusTone = "quiet", action, dimmed = false, booked = false, tag = null,
  alwaysRuns = false, stackAction = false, extraLine = null, coachAvatar = null, flexState = null,
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
  /**
   * A small mark beside the time — "Peak" today, and nothing else yet. It takes
   * the accent's TEXT step, never its fill: a mark sitting ON the card is
   * measured against the card, where the raw accent can be as low as 1.23.
   */
  tag?: React.ReactNode;
  /** Decision 22 amendment: a core (or always-runs) class. Tints the card with
   *  the studio accent at 0.12 and adds an "Always runs" chip at the end of the
   *  first line. Only passed when the studio runs guarantees. */
  alwaysRuns?: boolean;
  /** Decision 22(f): a flex class's state ("Be the first", "Needs 1 more",
   *  "Running"), shown next to the time. Null for core and for no flex. */
  flexState?: FlexChipInput | null;
  /** Decision 103(c): when the action label is more than one word, or the row
   *  is booked/held/owes a fee, the action sits on its own full-width line
   *  BELOW the text so the class name, coach and studio never truncate and the
   *  time stays on one line. */
  stackAction?: boolean;
  /** A second status line under the first (the flex "we'll confirm by" line on a
   *  pay-to-keep row), kept on its own line. */
  extraLine?: React.ReactNode;
  /** The coach's photo (instructors.avatar_url), shown as a 40px circle at the
   *  top right of the card beside the name; the Avatar component falls back to
   *  the coach's initials when there is no photo. */
  coachAvatar?: string | null;
}) {
  const muted = dimmed || statusTone === "full";
  // Decision 22(d): the accent bar sits OUTSIDE the content (flush at the card's
  // left edge), the time is its own line that grows with the text, the class
  // name wraps to two lines and is NEVER truncated, the Always runs chip drops
  // below the name when there is no room (flex-wrap), and the coach photo is a
  // fixed 40px circle at the top right. Checked at 360px with font scale 1.3.
  return (
    <li className={`m-card relative overflow-hidden py-4 pl-5 pr-4 ${booked ? "m-card-booked" : ""} ${dimmed ? "opacity-90" : ""}`}
        style={alwaysRuns ? { background: "var(--accent-chip)" } : undefined}>
      {/* The accent bar, flush outside the content. */}
      <span aria-hidden
            className="pointer-events-none absolute inset-y-0 left-0 w-1 rounded-r"
            style={{ background: muted ? "var(--line-2)" : "var(--accent-solid)" }} />
      <Link href={href} className="absolute inset-0" aria-label={`Open ${name}`}>
        <span className="sr-only">Open {name}</span>
      </Link>

      <div className="relative flex items-start gap-3">
        <div className="pointer-events-none min-w-0 flex-1">
          {/* The time on its own line, growing with the text. */}
          <p className="num m-time-lg text-ink">
            {startLabel}{endLabel ? <span className="text-ink-3"> – {endLabel}</span> : null}
            {tag ? <span className="ml-2 align-middle">{tag}</span> : null}
            {flexState ? <FlexChip state={flexState} className="ml-2 align-middle" /> : null}
          </p>

          {/* The name wraps and is never truncated; the chip drops below it. */}
          <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1">
            <p className={`m-name break-words ${muted ? "text-ink-3" : "text-ink"}`}>{name}</p>
            {alwaysRuns && (
              <span className="m-micro whitespace-nowrap rounded-full px-2 py-0.5"
                    style={{ background: "var(--surface)", color: "var(--lime-text)" }}>
                Always runs
              </span>
            )}
          </div>

          <p className="m-subtle mt-0.5 break-words text-ink-3">
            {/* Absent, not "TBC". Decision 17: an open shift reads as a normal
                class to a member, and a row saying nobody has agreed to teach it
                is a doubt they can do nothing with. */}
            {[instructor, room].filter(Boolean).join(" · ")}
          </p>
          <p className="m-subtle mt-1.5">
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
          {extraLine && <p className="m-subtle mt-0.5 break-words text-ink-3">{extraLine}</p>}
        </div>

        {/* The coach photo: a fixed 40px circle at the top right. */}
        {instructor && (
          <span className="pointer-events-none shrink-0">
            <Avatar name={instructor} url={coachAvatar} size={40} />
          </span>
        )}

        {/* A short single-word action (Book) sits beside the text. */}
        {!stackAction && (
          <div className="pointer-events-auto relative z-10 flex shrink-0 items-center">{action}</div>
        )}
      </div>

      {/* A multi-word or booked/held action sits full-width below the text. */}
      {stackAction && action && (
        <div className="pointer-events-auto relative z-10 mt-3">{action}</div>
      )}
    </li>
  );
}
