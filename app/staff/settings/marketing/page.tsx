import Link from "next/link";
import { staffScreen } from "@/lib/screen";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import SettingsBack from "../back";
import { savePostSettings } from "./actions";

export const dynamic = "force-dynamic";

/**
 * Settings → Marketing (Decision 93). The brand kit (slice 1) and schedule posts
 * (slice 2) each have their own screen; the post footer line and hashtags are
 * edited here. Desk-up may open the page; owners and managers edit the fields.
 */
export default async function MarketingSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Marketing"><Denied what="Marketing" role={ctx.role} /></AppShell>;
  }
  const canEdit = isManagerUp(ctx.role);
  const { data: s } = await supabase.from("studio_settings")
    .select("post_footer_line, post_hashtags").eq("studio_id", ctx.studioId).maybeSingle();
  const footer = s?.post_footer_line ?? "Book on the app";
  const hashtags = s?.post_hashtags ?? "";

  return (
    <AppShell {...shell} title="Marketing">
      <SettingsBack />
      <SectionLabel>Marketing</SectionLabel>
      <p className="mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        Your studio&rsquo;s look for social posts of the timetable.
      </p>

      <div id="brand-kit" className="mt-3 max-w-2xl rounded-lg border border-line bg-surface">
        <Link href="/settings/marketing/brand-kit" className="block px-4 py-3.5 hover:bg-paper">
          <p className="text-[14px] font-medium text-ink">Brand kit</p>
          <p className="mt-0.5 text-[13px] text-ink-2">
            Learn your studio&rsquo;s look from reference designs, for timetable posts.
          </p>
        </Link>
      </div>

      <div id="schedule-posts" className="mt-3 max-w-2xl rounded-lg border border-line bg-surface">
        <Link href="/settings/marketing/schedule-posts" className="block px-4 py-3.5 hover:bg-paper">
          <p className="text-[14px] font-medium text-ink">Schedule posts</p>
          <p className="mt-0.5 text-[13px] text-ink-2">
            Make a social post of your timetable in your studio&rsquo;s look.
          </p>
        </Link>
      </div>

      <div id="post-settings" className="mt-6 max-w-2xl scroll-mt-20">
        <SectionLabel>Post footer &amp; hashtags</SectionLabel>
        <form action={async (fd) => { "use server"; await savePostSettings(fd); }}
          className="mt-3 space-y-4 rounded-lg border border-line bg-surface p-4">
          <label className="block text-[13px] text-ink-2">
            Footer line on posts
            <input name="footer" defaultValue={footer} maxLength={120} disabled={!canEdit}
              placeholder="Book on the app"
              className="mt-1 block w-full rounded border border-line-2 bg-surface px-2.5 py-2 text-[14px] text-ink disabled:opacity-60" />
            <span className="mt-1 block text-[12px] text-ink-3">Shown at the foot of every timetable post.</span>
          </label>
          <label className="block text-[13px] text-ink-2">
            Hashtags
            <textarea name="hashtags" defaultValue={hashtags} maxLength={300} rows={2} disabled={!canEdit}
              placeholder="#yourstudio #pilates #reformer"
              className="mt-1 block w-full rounded border border-line-2 bg-surface px-2.5 py-2 text-[14px] text-ink disabled:opacity-60" />
            <span className="mt-1 block text-[12px] text-ink-3">Added to the end of the copied caption.</span>
          </label>
          {canEdit
            ? <button className="rounded-xl px-4 py-2 text-[14px] font-semibold"
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>Save</button>
            : <p className="text-[12px] text-ink-3">Owners and managers edit these.</p>}
        </form>
      </div>
    </AppShell>
  );
}
