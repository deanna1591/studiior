// Decision 100(a): every time staff see in the booking sheet is the STUDIO's
// local time in the studio's clock format, never the viewer's browser zone or
// locale. The day uses the studio zone; the time is the ONE clock formatter
// (fmtClock, which the roster's fmtTime wraps), so the sheet and the roster
// cannot disagree about the same instant. Plain ESM so node --test runs it.
import { fmtClock } from "./clock.mjs";

/** "Sun 22 Nov, 10:00 AM" (12h) / "Sun 22 Nov, 10:00" (24h), in the studio zone. */
export function staffWhen(iso, timeZone, format = "24h") {
  const day = new Intl.DateTimeFormat("en-GB",
    { timeZone, weekday: "short", day: "numeric", month: "short" }).format(new Date(iso));
  return `${day}, ${fmtClock(iso, timeZone, format)}`;
}
