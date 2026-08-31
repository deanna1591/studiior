import Link from "next/link";
import { Icon } from "./icons";

/**
 * One class, as a card.
 *
 * Rows were the right answer for the staff roster, where the job is to scan
 * forty names. They are the wrong answer here: a member sees six classes and
 * is deciding between them, so each one needs room to say what it is and to
 * look like something you press.
 *
 * The whole card opens the detail view and the action button books — two
 * targets in one card, which HTML will not let you nest (a form inside an
 * anchor is invalid, and a button inside one swallows the submit). The link is
 * therefore an absolutely positioned overlay and the action sits above it on
 * its own layer. The divider is what makes that legible to a person: the top
 * of the card is information and opens the detail, the bottom is the decision.
 *
 * No glass. A card sits on a flat surface with nothing behind it to refract,
 * and a blurred layer per card is paid for on every scroll frame.
 */
export default function ClassCard({
  href, timeRange, durationLabel, name, instructor, room,
  statusLabel, statusTone = "quiet", action, dimmed = false, booked = false,
}: {
  href: string;
  timeRange: React.ReactNode;
  durationLabel: React.ReactNode;
  name: string;
  instructor: string;
  room: string | null;
  statusLabel: React.ReactNode;
  statusTone?: "quiet" | "booked" | "full";
  action: React.ReactNode;
  dimmed?: boolean;
  booked?: boolean;
}) {
  return (
    <li className={`m-card relative ${booked ? "m-card-booked" : ""} ${dimmed ? "opacity-70" : ""}`}>
      {/* The tap-through. Sits under the action layer and carries the card's
          accessible name, so a screen reader gets "Open Barre" rather than a
          link with no text. */}
      <Link href={href} className="absolute inset-0 rounded-[16px]" aria-label={`Open ${name}`}>
        <span className="sr-only">Open {name}</span>
      </Link>

      <div className="pointer-events-none relative p-4">
        <div className="flex items-center gap-2">
          <span className="num text-[16px] font-semibold leading-6 text-ink">{timeRange}</span>
          {/* Only the digits are mono. "50 mins" set entirely in IBM Plex Mono
              reads as a code fragment; the number is the measurement, the word
              beside it is prose. */}
          <span className="rounded-full bg-paper px-2 py-0.5 text-[11px] leading-4 text-ink-2">
            {durationLabel}
          </span>
        </div>

        <p className={`mt-1.5 text-[17px] font-semibold leading-6 ${dimmed ? "text-ink-3" : "text-ink"}`}>
          {name}
        </p>

        <p className="m-sub mt-2 flex items-center gap-2 text-ink-2">
          <Icon name="person" size={16} className="shrink-0 text-ink-3" />
          {instructor}
        </p>
        {room && (
          <p className="m-sub mt-1 flex items-center gap-2 text-ink-2">
            <Icon name="door" size={16} className="shrink-0 text-ink-3" />
            {room}
          </p>
        )}

        <div className="mt-3.5 border-t border-line pt-3.5">
          <div className="flex min-h-[44px] items-center justify-between gap-3">
            <span
              className={`m-sub flex items-center gap-1.5 ${
                statusTone === "booked" ? "font-medium" : "text-ink-2"
              }`}
              style={statusTone === "booked" ? { color: "var(--lime-text)" } : undefined}
            >
              {statusTone === "booked" && <Icon name="tick" size={16} active />}
              {statusLabel}
            </span>
            {/* Only the action takes pointer events back. */}
            <span className="pointer-events-auto shrink-0">{action}</span>
          </div>
        </div>
      </div>
    </li>
  );
}
