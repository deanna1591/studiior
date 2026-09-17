import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { notifLabel, relTime, type NotifItem } from "@/lib/instructor-notify";
import { MarkNotificationsRead } from "./mark-read";

export const dynamic = "force-dynamic";

/**
 * NOTIFICATIONS — everything the studio has sent this instructor, read and
 * unread. Every notice built over the last week goes out by email; this is
 * where a deleted email comes back. `instructor_notifications` reads the rows
 * addressed to their login; opening the page marks them read (migration 157).
 */
export default async function NotificationsPage() {
  const { ctx, supabase } = await instructorScreen();
  const { data } = await supabase.rpc("instructor_notifications", {
    p_instructor_id: ctx.instructor_id, p_limit: 50,
  });
  const items = ((data as { items?: NotifItem[] } | null)?.items ?? []);

  return (
    <InstructorShell ctx={ctx} title="Notifications">
      <MarkNotificationsRead instructorId={ctx.instructor_id} />
      {items.length === 0 ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nothing yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            Anything the studio sends you — a class to teach, a cover request, an
            approval — turns up here as well as in your email.
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {items.map((n) => {
            const { title } = notifLabel(n.template_key);
            return (
              <li key={n.id} className="m-card flex items-start gap-3 px-3.5 py-3"
                  style={!n.read ? { boxShadow: "inset 0 0 0 1.5px var(--accent-chip)" } : undefined}>
                <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full"
                      style={{ background: n.read ? "var(--line-2)" : "var(--lime-text)" }} />
                <span className="min-w-0 flex-1">
                  <span className={`block text-[14.5px] leading-5 ${n.read ? "text-ink-2" : "text-ink"}`}>{title}</span>
                  <span className="m-sub block text-ink-3">{relTime(n.created_at)}</span>
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </InstructorShell>
  );
}
