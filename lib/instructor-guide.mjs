// Decision 85 (85a) + amendment (a) — the Studio Guide for instructors. The
// wording here is the decision record, carried verbatim
// (docs/STUDIIOR_V1_DECISIONS.md ## 85). It is platform-wide and studio-neutral;
// {studio_name} is the ONLY token, filled in by the screen that renders it; no
// prices, no studio names, no em dashes. Plain ESM so node --test reads it with
// no bundler; the app imports it through the .d.ts.
//
// AMENDMENT (a): the guide shows the thing to tap, not just its name. Each step
// carries zero or more ui refs {kind:'tab'|'button'|'screen', key}; the app
// draws each from its own components (lib/guide-ui-registry.mjs +
// components/instructor/guide-ui.tsx), so a chip always matches the instructor's
// real screen and the studio's theme. No raw bracket notation ever reaches the
// screen — the brackets in the record become structured refs here.
//
// GO PATHS: each section links to the real screen it describes. "Checking in",
// "Walk-ins" and "Payments at the desk" all happen on a class roster, reached
// via /instructor/roster (an index that sends you to My schedule to pick one);
// "Can't make a class" is /instructor/open (an index that sends you to
// /instructor/shifts). Both index routes exist so every go path resolves.

/** A ui ref: the real control a line is about. */
const tab = (key) => ({ kind: "tab", key });
const button = (key) => ({ kind: "button", key });

/** The five-card first-open intro. Card one carries the {studio_name} token.
 *  `refs` are the controls the card names, shown as chips after the body. */
export const INTRO_CARDS = [
  {
    title: "Welcome to {studio_name}",
    body: "Your roster, your pay and your schedule are all here. These are the five things you will use most.",
    refs: [tab("My schedule"), tab("Open classes"), tab("My pay"), tab("Me")],
  },
  {
    title: "Check everyone in",
    body: "Check in every member before class starts. Scan their code or tap their name. Anyone not checked in is marked as a no-show after class.",
    refs: [button("Check in")],
  },
  {
    title: "Walk-ins",
    body: "Someone at the door who is not on the roster? Tap Add a walk-in at the bottom of the roster. The app does the rest.",
    refs: [button("Add a walk-in")],
  },
  {
    title: "Payments at the desk",
    body: "Take the payment from the client first, then record it in the app. Every payment is saved under your name.",
    refs: [button("Paid at desk"), button("Sold a plan at desk")],
  },
  {
    title: "Can't make a class?",
    body: "Ask for cover from the class. The class is still yours until someone else takes it. And tap Checked in for pay at every class. That is what releases your pay.",
    refs: [button("Ask for cover"), button("Checked in for pay")],
  },
];

/** The label on the last intro card's button. */
export const INTRO_DONE_LABEL = "Got it";

/** The one-line first-time hints, keyed by screen — the DB records each once
 *  dismissed (instructor_guide_mark). The three keys are the whole set. Each
 *  carries the one control its line names. */
export const HINTS = {
  roster: {
    text: "Check in everyone before class starts. Walk-ins are at the bottom.",
    refs: [button("Check in")],
  },
  pay: {
    text: "Tap Checked in for pay at every class. It releases your pay.",
    refs: [button("Checked in for pay")],
  },
  cover: {
    text: "The class is still yours until someone else takes it.",
    refs: [button("Can't make it")],
  },
};

/** The Studio Guide screen's sections. `go` is the screen the section is about.
 *  `important` is the one bordered box per section (a rule that costs money or
 *  trust if missed). `intro` is an un-numbered lead line. Each step is a
 *  numbered instruction with inline refs, OR a `screen` picture with a caption. */
export const SECTIONS = [
  {
    title: "Before class",
    go: "/instructor/schedule",
    steps: [
      { text: "Arrive 15 minutes early. Open My schedule. Today's classes are listed with how many people are booked.", refs: [tab("My schedule")] },
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
      { text: "Fastest: tap Scan a member's code and scan the QR code on their phone. Their row is ticked.", refs: [button("Scan a member's code")] },
      { text: "No phone? Tap Check in on their row.", refs: [button("Check in")] },
      { text: "Check everyone in ticks everyone at once. Use it only after you have counted the room. It also ticks people who are not there.", refs: [button("Check everyone in")] },
      { text: "If the app says They need to sign the studio waiver first: they sign on your phone, or on paper. For paper, tap Paper waiver signed on their row. No waiver, no class.", refs: [button("Paper waiver signed")] },
      { text: "If the app says They aren't booked into this class: they are a walk-in. See the next section." },
      { text: "If the app says The check-in window is closed: it is too early. It opens on its own before class." },
    ],
  },
  {
    title: "Walk-ins",
    go: "/instructor/roster",
    intro: "A walk-in is anyone in the studio who is not on your roster.",
    steps: [
      { text: "Scroll to the bottom of the roster. Tap Add a walk-in.", refs: [button("Add a walk-in")] },
      { screen: "Add a walk-in", caption: "Type their details and tap Add. The line under the button tells you what happened." },
      { text: "Type their name, email and mobile. Tap Add. The line under the button tells you what happened.", refs: [button("Add")] },
      { text: "Added, free first class: a new member. Their account is created, they are booked and checked in. Nothing to pay. Give them the waiver." },
      { text: "Added, on their plan: a member with classes left. Nothing to pay." },
      { text: "Added, drop-in, amount due: a member with no plan. They pay before class and you record it. See Payments at the desk." },
      { text: "They're booked into another class today: tap Move them here. Their booking moves to this class, no fee, and they are checked in.", refs: [button("Move them here")] },
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
      { text: "Drop-in paid: tap Paid at desk. Choose GCash, Cash or Card. Keep the amount. Type the reference number if there is one. Tap Record payment. The row turns paid and the member gets a receipt.", refs: [button("Paid at desk"), button("Record payment")] },
      { text: "Buying a plan: tap Sold a plan at desk. Choose the plan (the price fills in), the method, the reference. Tap Record sale. The plan starts today.", refs: [button("Sold a plan at desk"), button("Record sale")] },
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
      { text: "Forgot someone? Check them in before you leave: My schedule, tap the class, tap Check in on their row.", refs: [tab("My schedule"), button("Check in")] },
      { text: "If the class is already closed (the row is grey), message the studio with the name and the class. They will fix it." },
      { text: "If a class ends with nobody checked in, you get a notification. Open the roster and check in everyone who came." },
    ],
  },
  {
    title: "Can't make a class",
    go: "/instructor/open",
    important: "The class is still yours until someone else takes it and the studio approves. Asking is not the same as covered.",
    steps: [
      { text: "Open My schedule, tap the class, tap Can't make it.", refs: [tab("My schedule"), button("Can't make it")] },
      { text: "Say why, then choose a colleague or Anyone who can take it. Send." },
      { text: "You will get a notification when it is covered. Until then, you are teaching it." },
      { text: "To take someone else's class, open Open classes and tap Take this class. If it fits your availability, it is yours right away. If not, the studio decides.", refs: [tab("Open classes"), button("Take this class")] },
      { text: "Fill in My availability under Me every month before the schedule is made.", refs: [tab("Me")] },
    ],
  },
  {
    title: "Your pay",
    go: "/instructor/pay",
    important: "Tap Checked in for pay at every class you teach, including covers. It releases your pay for that class.",
    steps: [
      { text: "Checked in for pay is at the top of every roster. Tap it when you arrive.", refs: [button("Checked in for pay")] },
      { text: "Open My pay to see this period and past statements: each class, the rate, covers, and the total.", refs: [tab("My pay")] },
      { text: "If you have any questions about your statement or your pay, send them to the studio from that screen. That keeps your question with the statement." },
      { text: "Desk payments you took is also on My pay. This is the studio's money you recorded at the desk, listed so you can balance the terminal and e-wallet at the end of the day. It is not part of your pay.", refs: [tab("My pay")] },
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
