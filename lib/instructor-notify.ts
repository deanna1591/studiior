/**
 * Human labels for the instructor's in-app notification list.
 *
 * The email body carries the full detail; the in-app list gives the gist and a
 * timestamp so a deleted email can be found again. One fixed sentence per
 * template key rather than interpolating a payload whose shape varies template
 * to template — an honest label the studio wrote beats a half-built one.
 *
 * `action` marks the few that are still WAITING on the instructor, so home can
 * lift those out of the stream.
 */
export type NotifItem = {
  id: string; template_key: string; payload: Record<string, unknown>;
  created_at: string; read: boolean;
};

const LABELS: Record<string, { title: string; action?: boolean }> = {
  instructor_assigned:            { title: "You were assigned a class" },
  shift_approved:                 { title: "Your claim was approved — the class is yours" },
  shift_declined:                 { title: "A claim was not approved" },
  shift_taken_off:                { title: "You were taken off a class" },
  open_shifts_available:          { title: "There are open classes to claim", action: true },
  class_reassigned_off:           { title: "A class was moved to someone else" },

  month_roster:                   { title: "Your roster for the month is ready", action: true },
  week_confirm_ask:               { title: "Confirm this week’s classes", action: true },
  week_confirm_reminder:          { title: "Still to confirm this week", action: true },

  availability_approved:          { title: "Your availability was approved" },
  availability_changes_requested: { title: "The studio asked for changes to your availability", action: true },
  availability_due:               { title: "Your availability is due", action: true },
  availability_narrowed_instructor: { title: "Some classes fall in hours you removed", action: true },

  cover_available:                { title: "A class needs cover", action: true },
  cover_approved:                 { title: "Your cover request was approved" },
  cover_declined:                 { title: "Your cover request was declined" },

  flex_going_ahead:               { title: "A flex class reached its minimum" },
  flex_confirmed:                 { title: "A flex class is confirmed" },
  flex_cancelled:                 { title: "A flex class is not running" },
  core_committed:                 { title: "A class is going ahead" },
  booking_cancelled_committed:    { title: "A member cancelled a class you are committed to" },
  commitment_digest:              { title: "Your teaching this term" },
};

export function notifLabel(templateKey: string): { title: string; action: boolean } {
  const l = LABELS[templateKey];
  return { title: l?.title ?? "An update from the studio", action: l?.action ?? false };
}

/** Short relative time — "just now", "3h ago", "Mon 10 Nov". */
export function relTime(iso: string): string {
  const then = new Date(iso).getTime();
  const mins = Math.round((Date.now() - then) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.round(hrs / 24);
  if (days < 7) return `${days}d ago`;
  return new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short" }).format(new Date(iso));
}
