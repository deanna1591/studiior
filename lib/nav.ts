import type { StaffContext } from "@/lib/auth";
import { isManagerUp } from "@/lib/auth";
import type { RailItem } from "@/components/rail";

/** A rail section. A null heading renders its items bare, at the top. */
export type RailGroup = { heading: string | null; items: RailItem[] };

/**
 * What the rail offers this role, in groups.
 *
 * The rail is convenience, not security — every destination is guarded by its
 * own policy, and typing a URL gets a refusal from the database rather than
 * from a hidden link. But a link that would only ever refuse is noise, so each
 * item carries the same gate its screen does, and a group with nothing this
 * role may see is dropped entirely rather than left as an empty heading.
 *
 * Grouping (rather than one flat list of eighteen) so the rail is a nav you
 * use, not a list you scan — the same move `/settings` made. The headings name
 * a domain; the items name a screen, so nothing reads as two names for one
 * thing. In particular there is no "Calendar": the timetable has two screens
 * and they are genuinely different — **Schedule** is the live, dated day/week
 * view you drag classes around in (`/schedule`), and **Recurring classes** is
 * the standing weekly template that generates them (`/series`). Both labels
 * match their own page titles; the **Timetable** heading carries the domain so
 * the group is not "Schedule" containing "Schedule".
 *
 * Setup is deliberately NOT here — it is a one-time task and already a row in
 * the dashboard action centre, which appears while it is unfinished and clears
 * itself when it is done. A permanent rail link to it is clutter every day
 * after the first.
 */
export function railGroups(
  ctx: StaffContext,
  isPlatformAdmin = false,
  hasChallenges = false,
): RailGroup[] {
  const manager = isManagerUp(ctx.role);
  const instructor = ctx.role === "instructor";
  const desk = ctx.role === "front_desk" || manager;

  // Top block, no heading. Dashboard for everyone; an instructor's own three
  // jobs sit here too — their staff-app rail is short enough that a heading
  // over them would be noise (Decision 17/18: their reason to open the staff
  // app at all is to see what is going and confirm the week they are down for).
  const top: RailItem[] = [{ href: "/", label: "Dashboard" }];
  if (instructor) {
    top.push(
      { href: "/my/week", label: "My week" },
      { href: "/my/availability", label: "My availability" },
      { href: "/shifts", label: "Open shifts" },
    );
  }

  const groups: RailGroup[] = [
    { heading: null, items: top },

    // Everything about your members. Members and the who-owes-money list are
    // front-desk work; importing and announcements are manager-up — so front
    // desk sees a two-item People group and a manager sees four.
    {
      heading: "People",
      items: [
        { href: "/members", label: "Members" },
        // §9 reads front desk's "Payments" as TAKING payment, and the desk is
        // who chases one. Not manager-up; not the instructor.
        ...(desk ? [{ href: "/due", label: "Payments due" }] : []),
        ...(manager
          ? [
              { href: "/imports", label: "Import" },
              // Decision 27. A basic studio tool, always available to managers.
              { href: "/announcements", label: "What’s on" },
            ]
          : []),
      ],
    },

    // The timetable, in all its forms. Manager-up.
    {
      heading: "Timetable",
      items: manager
        ? [
            { href: "/schedule", label: "Schedule" },
            { href: "/series", label: "Recurring classes" },
            // Decision 18. Staff always approve cover, so an unanswered request
            // is its own emergency with somewhere to live that is not a banner.
            { href: "/shifts/cover", label: "Cover" },
            // Decision 25. Only when publication is on: for every other studio a
            // month is live the moment it is made, so a Publish link would open
            // a screen with nothing to do.
            ...(ctx.publicationEnabled ? [{ href: "/publish", label: "Publish" }] : []),
            // Decision 27 closures. Also reachable from the settings hub; here
            // because a closure is a change to the timetable, not a setting.
            { href: "/settings/closures", label: "Closures" },
          ]
        : [],
    },

    // The instructors, and what the studio owes them. Manager-up.
    {
      heading: "Team",
      items: manager
        ? [
            { href: "/instructors", label: "Instructors" },
            // Submissions to review, who has not sent one, and the week's
            // unconfirmed line — one place rather than three.
            { href: "/availability", label: "Availability" },
            // Decision 28. Pay periods: what each instructor is owed, releasing
            // held records, proof of payment. Manager-up — this is money owed to
            // a named person, not the desk's takings (/due is theirs).
            { href: "/pay", label: "Pay" },
          ]
        : [],
    },

    // What the studio sells. Manager-up. Plans is always here for a manager, so
    // the group never goes empty on Challenges being off — but the drop-empty
    // rule below is what makes that safe rather than assumed.
    {
      heading: "Selling",
      items: manager
        ? [
            { href: "/plans", label: "Plans" },
            // §9 challenges — shown once the studio turns the switch on in
            // Settings or already has one (Decisions 24/25: no trace otherwise).
            ...(hasChallenges ? [{ href: "/challenges", label: "Challenges" }] : []),
          ]
        : [],
    },

    // The studio itself — the rooms and class types classes are made of, the
    // settings behind them, and (owner only) what members see.
    {
      heading: "Studio",
      items: manager
        ? [
            { href: "/rooms", label: "Rooms" },
            { href: "/class-types", label: "Class types" },
            { href: "/settings", label: "Settings" },
            // Studio identity is the owner's (Decision 8's precedent for
            // studio-level settings sitting above Manager).
            ...(ctx.role === "owner" ? [{ href: "/branding", label: "Member app" }] : []),
          ]
        : [],
    },
  ];

  // A platform admin who is also studio staff gets the platform screen at the
  // bottom, on its own — it is a different app, not part of any group.
  if (isPlatformAdmin) groups.push({ heading: null, items: [{ href: "/admin", label: "Admin" }] });

  // Drop any group this role sees nothing in, so a heading never stands over
  // an empty section (front desk sees no Timetable/Team/Selling/Studio at all).
  return groups.filter((g) => g.items.length > 0);
}
