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
      {/* A bell with a clapper, not a dome. At 20px a domed bell with no clapper
          reads as an upturned cup. */}
      {name === "bell" && (
        <>
          <path d="M6 9.5a5 5 0 0 1 10 0c0 3.2.8 4.6 1.5 5.5H4.5C5.2 14.1 6 12.7 6 9.5Z" {...s} />
          <path d="M9.2 18a2 2 0 0 0 3.6 0" {...s} />
        </>
      )}
      {name === "user" && (
        <>
          <circle cx="11" cy="7.6" r="3.3" {...s} />
          <path d="M4.6 18.6a6.4 6.4 0 0 1 12.8 0" {...s} />
        </>
      )}
      {/* Streak. A flame with an inner core, so it does not read as a leaf. */}
      {name === "flame" && (
        <>
          <path d="M11 2.8c3.2 3 5 5.4 5 8.2a5 5 0 0 1-10 0c0-1.6.7-3 2-4.4.3 1.3.9 2.1 1.8 2.4.5-2.3.9-4 1.2-6.2Z" {...s} />
        </>
      )}
      {/* Credits: a ticket, because that is what a class pack is. */}
      {name === "ticket" && (
        <>
          <path d="M3 7.5a1.5 1.5 0 0 1 1.5-1.5h13A1.5 1.5 0 0 1 19 7.5v1.8a1.7 1.7 0 0 0 0 3.4v1.8a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 3 14.5v-1.8a1.7 1.7 0 0 0 0-3.4Z" {...s} />
          <path d="M13 6.6v1.8M13 13.6v1.8" {...s} />
        </>
      )}
      {name === "camera" && (
        <>
          <path d="M3 8.6A1.6 1.6 0 0 1 4.6 7h2L8 5h6l1.4 2h2A1.6 1.6 0 0 1 19 8.6v7.8A1.6 1.6 0 0 1 17.4 18H4.6A1.6 1.6 0 0 1 3 16.4Z" {...s} />
          <circle cx="11" cy="12" r="3.1" {...s} />
        </>
      )}
      {name === "phone" && (
        <path d="M7.2 3.8 9 7.4l-1.7 1.7a11 11 0 0 0 5.6 5.6L14.6 13l3.6 1.8v3.4a.8.8 0 0 1-.9.8C9.6 18.4 3.6 12.4 2.8 4.7a.8.8 0 0 1 .8-.9Z" {...s} />
      )}
      {/* Emergency contact: a shield, not a cross. A red cross reads medical. */}
      {name === "shield" && (
        <path d="M11 3 17.5 5.4v5c0 4-2.7 7.2-6.5 8.6-3.8-1.4-6.5-4.6-6.5-8.6v-5Z" {...s} />
      )}
      {name === "chevron-down" && <path d="M5.5 8.5 11 14l5.5-5.5" {...s} />}
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
  | "person" | "door" | "chevron-left" | "chevron-right" | "chevron-down"
  | "tick" | "certificate" | "bell" | "user" | "flame" | "ticket"
  | "camera" | "phone" | "shield";
