// Decision 85 (85a) + amendment (a) — the Studio Guide for instructors. The
// wording here is the decision record, carried verbatim
// (docs/STUDIIOR_V1_DECISIONS.md ## 85). It is platform-wide and studio-neutral;
// {studio_name} is the ONLY token, filled in by the screen that renders it; no
// prices, no studio names, no em dashes. Plain ESM so node --test reads it with
// no bundler; the app imports it through the .d.ts.
//
// AMENDMENT (a): the guide shows the thing to tap, not just its name. Each line
// carries its [tab X] / [button X] markers INLINE, exactly where the control is
// named — "Open [tab My schedule], tap the class, tap [button Can't make it]."
// splitGuideText() parses a line into text runs and ui refs, and
// components/instructor/guide-ui.tsx renders a run of text as text and a ref as a
// chip drawn from the app's own idiom (lib/guide-ui-registry.mjs), inline on the
// baseline. So a chip always sits where the word is, matches the instructor's
// real screen and the studio's theme, and no raw bracket ever reaches the DOM:
// every marker resolves to a registry chip, every other character is plain text.
// A [screen X] is NOT inline — it is a full-width picture, carried as a `screen`
// step (guide-ui.tsx GuideScreen).
//
// GO PATHS: each section links to the real screen it describes. "Checking in",
// "Walk-ins" and "Payments at the desk" all happen on a class roster, reached
// via /instructor/roster (an index that sends you to My schedule to pick one);
// "Can't make a class" is /instructor/open (an index that sends you to
// /instructor/shifts). Both index routes exist so every go path resolves.

/** Parse a guide line into runs: plain text and inline ui refs. The ONE parser
 *  the renderer and the node test share, so the test asserts on exactly what the
 *  screen draws — a text run never contains a bracket, a ref run always resolves
 *  to a registry key, so nothing bracketed survives into the HTML. */
const GUIDE_MARKER = /\[(tab|button) ([^\]]+)\]/g;
export function splitGuideText(text) {
  const runs = [];
  let last = 0;
  let m;
  GUIDE_MARKER.lastIndex = 0;
  while ((m = GUIDE_MARKER.exec(text)) !== null) {
    if (m.index > last) runs.push({ t: "text", value: text.slice(last, m.index) });
    runs.push({ t: "ref", kind: m[1], key: m[2] });
    last = m.index + m[0].length;
  }
  if (last < text.length) runs.push({ t: "text", value: text.slice(last) });
  return runs;
}

/** The five-card first-open intro. Card one carries the {studio_name} token.
 *  The controls a card names are chips, inline in the body where the record
 *  places them (a trailing group for the cards). */
export const INTRO_CARDS = [
  {
    title: "Welcome to {studio_name}",
    body: "Your roster, your pay and your schedule are all here. These are the five things you will use most. [tab My schedule] [tab Open classes] [tab My pay] [tab Me]",
  },
  {
    title: "Check everyone in",
    body: "Check in every member before class starts. Scan their code or tap their name. Anyone not checked in is marked as a no-show after class. [button Check in]",
  },
  {
    title: "Walk-ins",
    body: "Someone at the door who is not on the roster? Tap Add a walk-in at the bottom of the roster. The app does the rest. [button Add a walk-in]",
  },
  {
    title: "Payments at the desk",
    body: "Take the payment from the client first, then record it in the app. Every payment is saved under your name. [button Paid at desk] [button Sold a plan at desk]",
  },
  {
    title: "Can't make a class?",
    body: "Ask for cover from the class. The class is still yours until someone else takes it. And tap Checked in for pay at every class. That is what releases your pay. [button Ask for cover] [button Checked in for pay]",
  },
];

/** The label on the last intro card's button. */
export const INTRO_DONE_LABEL = "Got it";

/** The one-line first-time hints, keyed by screen — the DB records each once
 *  dismissed (instructor_guide_mark). The three keys are the whole set. The
 *  control each names is a chip, inline at the end of the line. */
export const HINTS = {
  roster: { text: "Check in everyone before class starts. Walk-ins are at the bottom. [button Check in]" },
  pay: { text: "Tap Checked in for pay at every class. It releases your pay. [button Checked in for pay]" },
  cover: { text: "The class is still yours until someone else takes it. [button Can't make it]" },
};

/** The Studio Guide screen's sections. `go` is the screen the section is about.
 *  `important` is the one bordered box per section (a rule that costs money or
 *  trust if missed). `intro` is an un-numbered lead line. Each step is a
 *  numbered instruction whose text carries its chips inline, OR a `screen`
 *  picture with a caption. */
export const SECTIONS = [
  {
    title: "Before class",
    go: "/instructor/schedule",
    steps: [
      { text: "Arrive 15 minutes early. Open [tab My schedule]. Today's classes are listed with how many people are booked." },
      { text: "Tap your class to open the roster. You will see who is booked, who is already checked in, and a note on anyone who needs attention." },
      { screen: "Roster", caption: "Your roster before class. Every row needs a tick before you start." },
      { text: "Notes you may see on a row: First class on us (a first-timer, welcome them and show them around), Waiver not signed (they sign before class), Unpaid (they pay at the desk before class)." },
      { text: "Count the people in the room against the roster. The app never overbooks, so an extra person is in the wrong class. Check their booking time." },
      { text: "A class marked Not running is cancelled. If someone shows up for it, put them in the next class with a free seat. See Walk-ins." },
    ],
  },
  {
    title: "Checking in",
    go: "/instructor/roster",
    important: "Check in every member before class starts. Anyone not checked in is marked as a no-show, which may cost them a credit or a fee.",
    steps: [
      { text: "Fastest: tap [button Scan a member's code] and scan the QR code on their phone. Their row is ticked." },
      { text: "No phone? Tap [button Check in] on their row." },
      { text: "[button Check everyone in] ticks everyone at once. Use it only after you have counted the room. It also ticks people who are not there." },
      { text: "If the app says They need to sign the studio waiver first: they sign on your phone, or on paper. For paper, tap [button Paper waiver signed] on their row. No waiver, no class." },
      { text: "If the app says They aren't booked into this class: they are a walk-in. See the next section." },
      { text: "If the app says The check-in window is closed: it is too early. It opens on its own before class." },
    ],
  },
  {
    title: "Walk-ins",
    go: "/instructor/roster",
    intro: "A walk-in is anyone in the studio who is not on your roster.",
    steps: [
      { text: "Scroll to the bottom of the roster. Tap [button Add a walk-in]." },
      { screen: "Add a walk-in", caption: "Type their details and tap Add. The line under the button tells you what happened." },
      { text: "Type their name, email and mobile. Tap [button Add]. The line under the button tells you what happened." },
      { text: "Added, free first class: a new member. Their account is created, they are booked and checked in. Nothing to pay. Give them the waiver." },
      { text: "Added, on their plan: a member with classes left. Nothing to pay." },
      { text: "Added, drop-in, amount due: a member with no plan. They pay before class and you record it. See Payments at the desk." },
      { text: "They're booked into another class today: tap [button Move them here]. Their booking moves to this class, no fee, and they are checked in." },
      { text: "This class is full: the app shows the next classes with free seats. Offer one of those. Never add a seat over capacity." },
    ],
  },
  {
    title: "Payments at the desk",
    go: "/instructor/roster",
    important: "Take the payment from the client first, then record it in the app. Only record a payment you saw go through. Every payment is saved under your name.",
    steps: [
      { text: "An unpaid seat shows Unpaid and the amount on its row, with two buttons." },
      { screen: "Paid at desk", caption: "Take the payment from the client first, then record it here." },
      { text: "Drop-in paid: tap [button Paid at desk]. Choose GCash, Cash or Card. Keep the amount. Type the reference number if there is one. Tap [button Record payment]. The row turns paid and the member gets a receipt." },
      { text: "Buying a plan: tap [button Sold a plan at desk]. Choose the plan (the price fills in), the method, the reference. Tap [button Record sale]. The plan starts today." },
      { text: "If they are in this class as an unpaid drop-in, tick Use it for today's class before you record the sale. Today's class comes off the new plan, so they do not pay twice." },
      { text: "You can only record payments for a class you are teaching today. For any other day, they pay online or on their next visit." },
      { text: "Refunds and plan changes are done by the studio, not you. Pass it on." },
    ],
  },
  {
    title: "After class",
    go: "/instructor/schedule",
    intro: "If everyone was checked in, you are done. After the class ends, the app marks check-ins as attended and everyone else as no-shows.",
    steps: [
      { text: "Forgot someone? Check them in before you leave: [tab My schedule], tap the class, tap [button Check in] on their row." },
      { text: "If the class is already closed (the row is grey), message the studio with the name and the class. They will fix it." },
      { text: "If a class ends with nobody checked in, you get a notification. Open the roster and check in everyone who came." },
    ],
  },
  {
    title: "Can't make a class",
    go: "/instructor/open",
    important: "The class is still yours until someone else takes it and the studio approves. Asking is not the same as covered.",
    steps: [
      { text: "Open [tab My schedule], tap the class, tap [button Can't make it]." },
      { text: "Say why, then choose a colleague or Anyone who can take it. Send." },
      { text: "You will get a notification when it is covered. Until then, you are teaching it." },
      { text: "To take someone else's class, open [tab Open classes] and tap [button Take this class]. If it fits your availability, it is yours right away. If not, the studio decides." },
      { text: "Fill in My availability under [tab Me] every month before the schedule is made." },
    ],
  },
  {
    title: "Your pay",
    go: "/instructor/pay",
    important: "Tap Checked in for pay at every class you teach, including covers. It releases your pay for that class.",
    steps: [
      { text: "[button Checked in for pay] is at the top of every roster. Tap it when you arrive." },
      { text: "Open [tab My pay] to see this period and past statements: each class, the rate, covers, and the total." },
      { text: "If you have any questions about your statement or your pay, send them to the studio from that screen. That keeps your question with the statement." },
      { text: "Desk payments you took is also on [tab My pay]. This is the studio's money you recorded at the desk, listed so you can balance the terminal and e-wallet at the end of the day. It is not part of your pay." },
    ],
  },
  {
    title: "Who to call",
    go: "/instructor/me",
    intro: "These are handled by the studio, not in the app. If a member asks, tell them the studio will sort it, and pass it on the same day.",
    steps: [
      { text: "Refunds, wrong charges, plan changes, or a no-show they say is unfair: message the studio with the name, the class and what happened." },
      { text: "Injury or anything medical: first aid first, then call the studio." },
      { text: "A member who cannot log in: they tap Forgot your password? on the login screen. Nothing for you to do." },
      { text: "A class record that is wrong after the class closed: message the studio with the name and the class." },
      { text: "Terminal or e-wallet down: let the member take the class, leave the row unpaid, and tell the studio. They pay next visit." },
      { text: "You see today's roster only, not member profiles or payment history. That is by design." },
    ],
  },
];

/** Fill {studio_name} in any guide string. The only token. */
export function fillStudio(text, studioName) {
  return text.split("{studio_name}").join(studioName);
}
