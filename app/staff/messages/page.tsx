import Link from "next/link";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { signAvatars } from "@/lib/avatars";
import { fmtDayLong, fmtTime } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * Decision 89 — the studio's message threads, newest first. Any non-instructor
 * staff role; an instructor is refused (they neither see nor send messages).
 */
export default async function MessagesList() {
  const screen = await staffScreen("/messages");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Messages"><Denied what="messages" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.rpc("staff_message_threads", { p_studio_id: ctx.studioId });
  const rows = (data ?? []) as Thread[];
  const photoMap = await signAvatars(supabase, rows.map((r) => r.photo_path));

  return (
    <AppShell {...shell} title="Messages">
      {rows.length === 0 ? (
        <p className="max-w-2xl text-[13px] leading-[20px] text-ink-2">
          No messages yet. When a member writes to the studio, their thread appears here.
        </p>
      ) : (
        <div className="max-w-2xl divide-y divide-line rounded border border-line bg-surface">
          {rows.map((r) => (
            <Link key={r.thread_id} href={`/messages/${r.thread_id}`}
                  className="flex items-center gap-3 px-3.5 py-3 hover:bg-paper">
              <Photo url={(r.photo_path ? photoMap.get(r.photo_path) : null) ?? null} name={r.member_name} />
              <span className="min-w-0 flex-1">
                <span className="flex items-center gap-2">
                  <span className="truncate text-[13px] font-semibold text-ink">{r.member_name}</span>
                  {r.unread && (
                    <span className="shrink-0 rounded px-1.5 py-0.5 text-[11px] font-semibold"
                          style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>Unread</span>
                  )}
                </span>
                <span className="mt-0.5 block truncate text-[12px] leading-[17px] text-ink-3">{r.latest}</span>
              </span>
              <span className="num shrink-0 text-[11px] text-ink-3">
                {r.last_message_at ? `${fmtDayLong(r.last_message_at, ctx.timeZone)} · ${fmtTime(r.last_message_at, ctx.timeZone, ctx.timeFormat)}` : ""}
              </span>
            </Link>
          ))}
        </div>
      )}
    </AppShell>
  );
}

function Photo({ url, name }: { url: string | null; name: string }) {
  if (url) return <img src={url} alt="" className="h-9 w-9 shrink-0 rounded-full object-cover" />;
  const initial = (name || "?").trim().charAt(0).toUpperCase();
  return (
    <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-paper text-[13px] font-semibold text-ink-2">
      {initial}
    </span>
  );
}

type Thread = {
  thread_id: string;
  member_id: string;
  member_name: string;
  photo_path: string | null;
  last_message_at: string | null;
  latest: string | null;
  unread: boolean;
};
