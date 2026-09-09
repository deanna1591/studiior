import type { StaffContext } from "@/lib/auth";
import { isManagerUp } from "@/lib/auth";
import type { RailItem } from "@/components/rail";

/**
 * What the rail offers this role. The rail is convenience, not security —
 * every destination below is guarded by its own policy, and typing the URL
 * gets a refusal from the database rather than from a hidden link.
 */
export function railItems(
  ctx: StaffContext,
  isPlatformAdmin = false,
  setupIncomplete = false,
): RailItem[] {
  const items: RailItem[] = [
    { href: "/", label: "Schedule" },
    { href: "/members", label: "Members" },
  ];
  // Decision 17: an instructor's whole reason to open the staff app is to see
  // what is going and say they will take it.
  // An instructor's own two jobs: confirm the week they are down for, and send
  // next month's availability. Both are guarded in the database — the rail is
  // convenience, and a manager reaching them by URL gets a real screen.
  if (ctx.role === "instructor") {
    items.push(
      { href: "/my/week", label: "My week" },
      { href: "/my/availability", label: "My availability" },
      { href: "/shifts", label: "Open shifts" },
    );
  }
  if (isManagerUp(ctx.role)) {
    // Setup leaves the rail the moment the list is finished. A permanent link
    // to a one-time task is clutter for every day after the first.
    if (setupIncomplete) items.push({ href: "/setup", label: "Setup" });
    // "Calendar", not "Schedule": "/" is already Schedule — the day list front
    // desk lives in — and two identical labels in one rail is worse than a
    // slightly loose word.
    items.push(
      { href: "/schedule", label: "Calendar" },
      // Decision 18. Staff always approve cover, so an unanswered request is
      // its own emergency and needs somewhere to live that is not a banner.
      { href: "/shifts/cover", label: "Cover" },
      // Submissions to review, who has not sent one, and the week's
      // unconfirmed line — one place rather than three.
      { href: "/availability", label: "Availability" },
    );
    items.push(
      // The standing timetable, above the one-off setup lists: a studio's week
      // is a set of recurring classes, and until now there was no way to make
      // one through the product at all.
      { href: "/series", label: "Recurring" },
      { href: "/plans", label: "Plans" },
      { href: "/rooms", label: "Rooms" },
      { href: "/class-types", label: "Class types" },
      { href: "/instructors", label: "Instructors" },
      { href: "/imports", label: "Import" },
    );
  }
  // Studio identity is the owner's, per Decision 8's precedent for
  // studio-level settings sitting above Manager.
  if (ctx.role === "owner") items.push({ href: "/branding", label: "Member app" });
  if (isPlatformAdmin) items.push({ href: "/admin", label: "Admin" });
  return items;
}
