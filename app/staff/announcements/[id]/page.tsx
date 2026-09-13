import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, SectionLabel } from "@/components/ui";
import AnnouncementForm from "../form";
import AnnouncementCover from "../cover";
import { publishAnnouncement, unpublishAnnouncement, deleteAnnouncement } from "../actions";

export const dynamic = "force-dynamic";

export default async function EditAnnouncement({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/announcements");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="What’s on"><Denied what="Announcements" role={ctx.role} /></AppShell>;

  const { data: a } = await supabase.from("announcements")
    .select("id, title, body, audience, pinned, starts_at, ends_at, status, image_url, image_focus_x, image_focus_y, notified_at")
    .eq("id", params.id).maybeSingle();
  if (!a) return <AppShell {...shell} title="What’s on"><Empty>Announcement not found.</Empty></AppShell>;

  const dateVal = (iso: string | null) => (iso ? iso.slice(0, 10) : "");

  return (
    <AppShell {...shell} title={a.title}>
      <Link href="/announcements" className="mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">← All announcements</Link>

      <div className="s-card mb-6 flex flex-wrap items-center gap-3 p-4">
        <span className="s-tag">{a.status}</span>
        {a.status === "draft" ? (
          <form action={publishAnnouncement} className="flex items-center gap-2">
            <input type="hidden" name="announcement_id" value={a.id} />
            <label className="flex items-center gap-1.5 text-[13px] text-ink-2">
              <input type="checkbox" name="notify" /> email members
            </label>
            <button className="rounded-full bg-ink px-4 py-2 text-[13px] font-semibold text-surface">Publish</button>
          </form>
        ) : (
          <form action={unpublishAnnouncement}>
            <input type="hidden" name="announcement_id" value={a.id} />
            <button className="rounded-full border border-line-2 bg-surface px-4 py-2 text-[13px] font-semibold text-ink">Unpublish</button>
          </form>
        )}
        <span className="text-[12px] text-ink-3">
          {a.status === "draft" ? "Members can’t see it yet." : a.notified_at ? "Live · members were emailed." : "Live on members’ Home."}
        </span>
      </div>

      <SectionLabel>Photo</SectionLabel>
      <div className="mb-6 mt-2">
        <AnnouncementCover id={a.id} imageUrl={a.image_url} focusX={a.image_focus_x} focusY={a.image_focus_y} />
      </div>

      <SectionLabel>Details</SectionLabel>
      <div className="mt-2">
        <AnnouncementForm mode="edit" values={{
          id: a.id, title: a.title, body: a.body, audience: a.audience, pinned: a.pinned,
          starts_on: dateVal(a.starts_at), ends_on: dateVal(a.ends_at),
        }} />
      </div>

      <form action={deleteAnnouncement} className="mt-8">
        <input type="hidden" name="announcement_id" value={a.id} />
        <button className="rounded-full border border-coral px-4 py-2 text-[13px] font-semibold text-coral">Delete</button>
      </form>
    </AppShell>
  );
}
