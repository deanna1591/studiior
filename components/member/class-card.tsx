import Link from "next/link";
import IconChip from "./icon-chip";
import Avatar from "./avatar";

/**
 * One class, as a card.
 *
 * Rows were right for the staff roster, where the job is to scan forty names.
 * A member sees six classes and is choosing between them, so each one gets room
 * to say what it is and to look like something you press.
 *
 * THE TYPE DOES THE WORK. The time is 24px and the instructor 13 — a ratio of
 * nearly two, where everything used to sit between 12 and 17 and the card read
 * as a paragraph. A member scanning a day is looking for a time, so the time is
 * the biggest thing on it.
 *
 * The whole card opens the detail view and the action button books — two
 * targets in one card, which HTML will not nest (a form inside an anchor is
 * invalid). The link is an overlay and the action sits above it on its own
 * layer; the divider is what makes that split legible to a person.
 *
 * No glass. A card sits on a flat surface with nothing behind it to refract,
 * and a blurred layer per card is paid for on every scroll frame.
 */
export default function ClassCard({
  href, timeRange, durationLabel, name, instructor, instructorAvatar, room,
  imageUrl, statusLabel, statusTone = "quiet", action, dimmed = false, booked = false,
}: {
  href: string;
  timeRange: React.ReactNode;
  durationLabel: React.ReactNode;
  name: string;
  instructor: string;
  instructorAvatar?: string | null;
  room: string | null;
  imageUrl?: string | null;
  statusLabel: React.ReactNode;
  statusTone?: "quiet" | "booked" | "full";
  action: React.ReactNode;
  dimmed?: boolean;
  booked?: boolean;
}) {
  return (
    <li className={`m-card relative ${booked ? "m-card-booked" : ""} ${dimmed ? "opacity-70" : ""}`}>
      <Link href={href} className="absolute inset-0 rounded-[22px]" aria-label={`Open ${name}`}>
        <span className="sr-only">Open {name}</span>
      </Link>

      <div className="pointer-events-none relative p-5">
        <div className="flex items-start gap-3">
          <div className="min-w-0 flex-1">
            <div className="flex items-baseline gap-x-2.5">
              <span className="num m-time whitespace-nowrap text-ink">{timeRange}</span>
              {/* --accent-chip, not --paper: on a card whose ground is
                  --accent-wash the paper fill was within a hair of the card and
                  the pill read as loose text. Label in --ink-2 (5.92 worst on
                  the tint); --ink-3 measures 3.72 there and would fail. */}
              <span className="shrink-0 whitespace-nowrap rounded-full px-2.5 py-1 text-[11px] leading-4 text-ink-2"
                    style={{ background: "var(--accent-chip)" }}>
                {durationLabel}
              </span>
            </div>
            <p className={`mt-1 text-[17px] font-semibold leading-6 ${dimmed ? "text-ink-3" : "text-ink"}`}>
              {name}
            </p>
          </div>

          {/* The class photograph. Small on a list card — it is here to tell
              one class from another at a glance, not to be the subject. */}
          {imageUrl && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={imageUrl} alt="" aria-hidden
                 className="h-12 w-12 shrink-0 rounded-[14px] object-cover" />
          )}
        </div>

        <div className="mt-4 space-y-2.5">
          <p className="m-meta flex items-center gap-2.5 text-ink-2">
            {instructorAvatar
              ? <Avatar name={instructor} url={instructorAvatar} size={32} />
              : <IconChip name="person" />}
            {instructor}
          </p>
          {room && (
            <p className="m-meta flex items-center gap-2.5 text-ink-2">
              <IconChip name="door" />
              {room}
            </p>
          )}
        </div>

        <div className="mt-5 border-t border-line pt-4">
          <div className="flex min-h-[44px] items-center justify-between gap-3">
            <span
              className={`m-sub flex items-center gap-1.5 ${
                statusTone === "booked" ? "font-medium" : "text-ink-2"
              }`}
              style={statusTone === "booked" ? { color: "var(--lime-text)" } : undefined}
            >
              {statusTone === "booked" && (
                <span className="flex h-5 w-5 items-center justify-center rounded-full"
                      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                  <svg width="12" height="12" viewBox="0 0 22 22" aria-hidden>
                    <path d="M4.5 11.5 9 16l8.5-9" fill="none" stroke="currentColor"
                          strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                </span>
              )}
              {statusLabel}
            </span>
            <span className="pointer-events-auto shrink-0">{action}</span>
          </div>
        </div>
      </div>
    </li>
  );
}
