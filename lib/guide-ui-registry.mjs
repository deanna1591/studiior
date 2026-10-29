// Decision 85 amendment (a) — the Studio Guide shows the real thing to tap, not
// just its name. This is the ONE registry that maps every ui key the guide
// content references to how the app draws it, so a chip in the guide and the
// real control it stands for are the same idiom and the same theme. Plain ESM
// so the node test can import these key sets with no bundler and assert every
// ref in the content has an entry here (a missing key fails the test);
// components/instructor/guide-ui.tsx turns an entry into JSX.

/** Tabs: the five instructor tabs, each by the icon the real tab bar uses
 *  (components/instructor/shell.tsx). The guide only ever names these four. */
export const TABS = {
  "My schedule": { icon: "calendar" },
  "Open classes": { icon: "ticket" },
  "My pay": { icon: "card" },
  "Me": { icon: "user" },
};

/** Buttons: each key is a control the instructor taps, mapped to the real app
 *  idiom it is drawn in — "solid" = the accent primary pill (CardAction /
 *  m-action), "tint" = ink on the accent chip (QuietButton / CardActionOutline),
 *  "outline" = the neutral secondary chip on a card (the desk's per-row
 *  buttons). Non-interactive; the styles come from guide-ui.tsx. */
export const BUTTONS = {
  "Check in": "tint",
  "Check everyone in": "solid",
  "Scan a member's code": "solid",
  "Paper waiver signed": "outline",
  "Add a walk-in": "solid",
  "Add": "solid",
  "Move them here": "outline",
  "Paid at desk": "outline",
  "Record payment": "solid",
  "Sold a plan at desk": "outline",
  "Record sale": "solid",
  "Ask for cover": "tint",
  "Can't make it": "tint",
  "Take this class": "solid",
  "Checked in for pay": "solid",
};

/** Screen pictures: a simplified, read-only rendering of a whole screen, built
 *  from the real components' own classes with made-up names. The key names
 *  which picture guide-ui.tsx draws; the caption travels with the content. */
export const SCREENS = {
  "Roster": true,
  "Add a walk-in": true,
  "Paid at desk": true,
};
