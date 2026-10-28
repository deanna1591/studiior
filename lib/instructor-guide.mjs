// Decision 85 — the Studio Guide for instructors (85a). The wording here is the
// decision record, carried verbatim (docs/STUDIIOR_V1_DECISIONS.md ## 85). It is
// platform-wide and studio-neutral; {studio_name} is the ONLY token, filled in
// by the screen that renders it. Plain ESM so node --test reads it with no
// bundler; the app imports it through the .d.ts.
//
// GO PATHS: each section links to the real screen it describes. "Checking in",
// "Walk-ins" and "Payments at the desk" all happen on a class roster, which is
// reached by tapping a class on /instructor/roster (an index that sends you to
// My schedule to pick one); "Can't make a class" is the Open classes screen,
// /instructor/open (an index that sends you to /instructor/shifts). Both index
// routes exist so every go path resolves.

/** The five-card first-open intro. Card one carries the {studio_name} token. */
export const INTRO_CARDS = [
  {
    title: "Welcome to {studio_name}",
    body: "This app is your roster, your pay and your schedule. Five things to know, thirty seconds.",
  },
  {
    title: "Check everyone in",
    body: "Before class starts, every person on the floor gets checked in. Scan their code or tap their name. Anyone left unchecked is marked a no-show after class.",
  },
  {
    title: "Walk-ins are one button",
    body: "Someone at the door who is not on the roster? Add a walk-in at the bottom of the roster. The app works out whether it is their free first class, their plan, or a drop-in.",
  },
  {
    title: "Take payment at the desk",
    body: "An unpaid seat shows Paid at desk and Sold a plan at desk. Take the money first, record it second. Every payment is tagged with your name.",
  },
  {
    title: "Can't make a class?",
    body: "Ask for cover from the class. The class stays yours until someone else has it. Your pay is released when you tap Checked in for pay.",
  },
];

/** The one-line first-time hints, keyed by screen. Each key is a hint the DB
 *  records once dismissed (instructor_guide_mark). The three keys are the whole
 *  set — a hint anywhere in the app is one of these. */
export const HINTS = {
  roster: "Check everyone in before class starts. Walk-ins go at the bottom.",
  pay: "Tap Checked in for pay at every class. It is what releases your pay.",
  cover: "The class stays yours until someone else has it.",
};

/** The Studio Guide screen's sections. `go` is the screen the section is about. */
export const SECTIONS = [
  {
    title: "Before class",
    go: "/instructor/schedule",
    lines: [
      "Arrive early, open My schedule, and read the roster before anyone arrives.",
      "Tap the class. You will see who is booked, who is checked in, and notes such as first class or waiver not signed.",
      "Count seats against bodies. The roster never lets a class overbook, so an extra person is in the wrong class.",
      "A class marked not running was cancelled. Anyone who turns up can go into the next class with a seat.",
    ],
  },
  {
    title: "Checking in",
    go: "/instructor/roster",
    lines: [
      "Every person must be checked in before class starts. It is what tells the system they came.",
      "Scan their code, or tap Check in on their row. Check everyone in checks in everyone still unticked, so only use it after you have counted.",
      "First class on us: a first-timer. Welcome them by name and show them around.",
      "Waiver not signed: they sign on your phone or on paper before they take the class.",
      "Not booked into this class: see Walk-ins.",
    ],
  },
  {
    title: "Walk-ins",
    go: "/instructor/roster",
    lines: [
      "Add a walk-in is at the bottom of the roster: name, email, mobile, then Add.",
      "New person: their account is created, the seat is their free first class, and they are checked in. They get one welcome email.",
      "Returning person: the app uses their plan if they have one, otherwise it is a drop-in to pay at the desk.",
      "Booked into another class today: the app offers Move them here. No fee, and they are checked in.",
      "Class full: the app lists the next classes with a free seat. Never add a seat beyond capacity.",
    ],
  },
  {
    title: "Payments at the desk",
    go: "/instructor/roster",
    lines: [
      "Take the money first, record it second, before class starts.",
      "An unpaid row shows the amount due. Tap Paid at desk, pick the method, add the reference, Record payment.",
      "Someone buying a plan: Sold a plan at desk, pick the plan, method, reference. Tick Use it for today's class if they are in this class as a drop-in.",
      "Every payment is recorded under your name. Never record a payment you did not see go through.",
      "Refunds and plan changes are not yours. Tell the studio.",
    ],
  },
  {
    title: "After class",
    go: "/instructor/schedule",
    lines: [
      "If everyone who came was checked in, there is nothing to do. The system closes the class for you.",
      "Forgot someone? Check them in before you leave. Once the class is closed, tell the studio and they will fix it.",
      "If a class ends with nobody checked in, you get a reminder. Open the roster and check people in while you remember.",
    ],
  },
  {
    title: "Can't make a class",
    go: "/instructor/open",
    lines: [
      "Open the class, tap Can't make it, say why, and ask a colleague or anyone who can take it.",
      "The class stays yours until someone else has it and the studio has approved. Do not assume.",
      "Open classes lists classes that need an instructor. Take this class makes it yours if it fits your availability.",
      "Fill in My availability each month before the studio builds the schedule.",
    ],
  },
  {
    title: "Your pay",
    go: "/instructor/pay",
    lines: [
      "Tap Checked in for pay when you arrive at every class. It releases your pay for that class.",
      "My pay shows each period, each class, covers, and the total.",
      "Desk payments you took are the studio's money, not your pay. They are listed so you can reconcile at the end of the day.",
      "A question on a statement goes to the studio from that screen.",
    ],
  },
  {
    title: "Who to call",
    go: "/instructor/me",
    lines: [
      "Refunds, plan changes, a wrong charge, a disputed no-show: the studio handles these. Pass it on the same day.",
      "Injury or anything medical: first aid, then call the studio.",
      "A member who cannot log in: Forgot your password on the login screen sends them a reset link.",
      "You see today's roster, not members' profiles or payment history. That is by design.",
    ],
  },
];

/** Fill {studio_name} in any guide string. The only token. */
export function fillStudio(text, studioName) {
  return text.split("{studio_name}").join(studioName);
}
