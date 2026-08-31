/**
 * The member app's icon set.
 *
 * Drawn on one 22×22 grid with one stroke weight, so a row of them reads as a
 * set rather than as five downloads. Stroke, never fill: a filled glyph at
 * 14px next to 15px text reads heavier than the text and pulls the eye off the
 * class name, which is the thing being scanned.
 *
 * `currentColor` throughout — every caller sets colour on the parent, so an
 * icon can never disagree with the label beside it.
 */
export function Icon({
  name, size = 22, active = false, className = "",
}: {
  name: IconName;
  size?: number;
  active?: boolean;
  className?: string;
}) {
  const s = {
    fill: "none" as const,
    stroke: "currentColor",
    strokeWidth: active ? 1.9 : 1.6,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };
  return (
    <svg width={size} height={size} viewBox="0 0 22 22" aria-hidden className={className}>
      {name === "home" && <path d="M3 9.5 11 3.5l8 6V18a1 1 0 0 1-1 1h-4v-5h-6v5H4a1 1 0 0 1-1-1z" {...s} />}
      {name === "calendar" && (
        <>
          <rect x="3" y="4.5" width="16" height="14" rx="2.5" {...s} />
          <path d="M3 9h16M7.5 3v3M14.5 3v3" {...s} />
        </>
      )}
      {name === "qr" && (
        <>
          <rect x="3" y="3" width="6.5" height="6.5" rx="1.4" {...s} />
          <rect x="12.5" y="3" width="6.5" height="6.5" rx="1.4" {...s} />
          <rect x="3" y="12.5" width="6.5" height="6.5" rx="1.4" {...s} />
          <path d="M12.5 12.5h3v3h-3zM19 19v-3M16 19h3" {...s} />
        </>
      )}
      {name === "clock" && (
        <>
          <circle cx="11" cy="11" r="8" {...s} />
          <path d="M11 6v5.5l3.5 2" {...s} />
        </>
      )}
      {name === "card" && (
        <>
          <rect x="2.5" y="5" width="17" height="12" rx="2.5" {...s} />
          <path d="M2.5 9.5h17" {...s} />
        </>
      )}
      {/* A person, for the instructor line. Shoulders wider than the head or it
          reads as a lollipop at 14px. */}
      {name === "person" && (
        <>
          <circle cx="11" cy="7.5" r="3.2" {...s} />
          <path d="M4.5 18.5a6.5 6.5 0 0 1 13 0" {...s} />
        </>
      )}
      {/* A door, for the room. A generic pin would say "location" — the room is
          inside the building the member is already standing in. */}
      {name === "door" && (
        <>
          <path d="M6 3.5h8a1 1 0 0 1 1 1v14H6z" {...s} />
          <path d="M4.5 18.5h13" {...s} />
          <circle cx="12.3" cy="11.4" r="0.9" fill="currentColor" stroke="none" />
        </>
      )}
      {name === "chevron-left" && <path d="M13 5.5 7.5 11l5.5 5.5" {...s} />}
      {name === "chevron-right" && <path d="M9 5.5 14.5 11 9 16.5" {...s} />}
      {name === "tick" && <path d="M4.5 11.5 9 16l8.5-9" {...s} />}
      {name === "certificate" && (
        <>
          <circle cx="11" cy="9" r="5.5" {...s} />
          <path d="M7.5 13.5 6.5 19l4.5-2.2L15.5 19l-1-5.5" {...s} />
        </>
      )}
    </svg>
  );
}

export type IconName =
  | "home" | "calendar" | "qr" | "clock" | "card"
  | "person" | "door" | "chevron-left" | "chevron-right" | "tick" | "certificate";
