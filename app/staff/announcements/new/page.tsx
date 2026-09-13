import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import AnnouncementForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewAnnouncement() {
  const screen = await staffScreen("/announcements");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="What’s on"><Denied what="Announcements" role={ctx.role} /></AppShell>;

  const today = new Date().toISOString().slice(0, 10);
  return (
    <AppShell {...shell} title="New announcement">
      <Link href="/announcements" className="mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">← All announcements</Link>
      <AnnouncementForm mode="new" values={{ title: "", body: "", audience: "members", pinned: false, starts_on: today, ends_on: "" }} />
    </AppShell>
  );
}
