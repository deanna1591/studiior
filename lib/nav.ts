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
  if (ctx.role === "instructor") items.push({ href: "/shifts", label: "Open shifts" });
  if (isManagerUp(ctx.role)) {
    // Setup leaves the rail the moment the list is finished. A permanent link
    // to a one-time task is clutter for every day after the first.
    if (setupIncomplete) items.push({ href: "/setup", label: "Setup" });
    // "Calendar", not "Schedule": "/" is already Schedule — the day list front
    // desk lives in — and two identical labels in one rail is worse than a
    // slightly loose word.
    items.push(
      { href: "/schedule", label: "Calendar" },
    );
    items.push(
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
