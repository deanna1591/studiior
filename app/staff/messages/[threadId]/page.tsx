import Link from "next/link";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { fmtDayLong, fmtTime } from "@/lib/time";
import MessageThread, { type ThreadMessage } from "@/components/messages/bubble";
import StaffReply from "../reply";
import DeleteConversation from "./delete";

export const dynamic = "force-dynamic";

/**
 * Decision 89 — one thread. The header carries the facts a studio wants while
 * replying (plan, an unpaid booking, their next class); the exchange and a reply
 * box sit below. Opening the thread marks it read.
 */
export default async function Thread({ params }: { params: { threadId: string } }) {
  const screen = await staffScreen("/messages");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Messages"><Denied what="messages" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.rpc("staff_message_thread", { p_thread_id: params.threadId });
  const t = data as ThreadDetail | null;
  if (!t?.ok) {
    return (
      <AppShell {...shell} title="Messages">
        <Link href="/messages" className="text-[13px] text-ink-2 underline">← Messages</Link>
        <p className="mt-4 text-[13px] text-ink-2">That thread could not be opened.</p>
      </AppShell>
    );
  }

  // Opening marks it read.
  await supabase.rpc("staff_mark_thread_read", { p_thread_id: params.threadId });

  // The studio accent — the staff app is otherwise unthemed, but the studio's
  // own bubbles carry its accent (Decision 89 (a)), the same as the member side.
  const { data: st } = await supabase.from("studios").select("accent_color").eq("id", ctx.studioId).maybeSingle();

  // Sign the attachments (the private message-attachments bucket) into a
  // path→url map, one wave.
  const signedUrls: Record<string, string> = {};
  await Promise.all((t.messages ?? []).map(async (m) => {
    if (!m.attachment_path) return;
    const { data: s } = await supabase.storage.from("message-attachments").createSignedUrl(m.attachment_path, 3600);
    if (s?.signedUrl) signedUrls[m.attachment_path] = s.signedUrl;
  }));

  const msgs: ThreadMessage[] = (t.messages ?? []).map((m) => ({
    id: m.id, sender_kind: m.sender_kind, body: m.body, created_at: m.created_at,
    attachment_path: m.attachment_path, attachment_name: m.attachment_name, attachment_mime: m.attachment_mime,
  }));
  const next = t.next_booking;
  const firstName = (t.member_name || "").trim().split(/\s+/)[0] || "this member";

  return (
    <AppShell {...shell} title="Messages">
      <Link href="/messages" className="text-[13px] text-ink-2 underline">← Messages</Link>

      <div className="mt-3 max-w-2xl rounded border border-line bg-surface px-4 py-3">
        <Link href={`/members/${t.member_id}`} className="text-[15px] font-semibold text-ink underline underline-offset-2">
          {t.member_name}
        </Link>
        <div className="mt-1.5 flex flex-wrap items-center gap-2">
          {t.plan_name && (
            <span className="rounded px-1.5 py-0.5 text-[11px]" style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
              {t.plan_name}
            </span>
          )}
          {t.has_unpaid_booking && (
            <span className="rounded px-1.5 py-0.5 text-[11px]" style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>
              Unpaid booking
            </span>
          )}
        </div>
        {next && (
          <p className="mt-1.5 text-[12px] text-ink-2">
            Next booking: {next.class_name}, {fmtDayLong(next.starts_at, ctx.timeZone)} · {fmtTime(next.starts_at, ctx.timeZone, ctx.timeFormat)}
          </p>
        )}
        <DeleteConversation threadId={params.threadId} firstName={firstName} />
      </div>

      <div className="mt-4 max-w-2xl">
        <MessageThread messages={msgs} tz={ctx.timeZone} timeFormat={ctx.timeFormat}
                       accent={st?.accent_color ?? null} signedUrls={signedUrls} />
      </div>

      <div className="mt-4 max-w-2xl">
        <StaffReply studioId={ctx.studioId} threadId={params.threadId} />
      </div>
    </AppShell>
  );
}

type ThreadDetail = {
  ok: boolean;
  member_id: string;
  member_name: string;
  plan_name: string | null;
  has_unpaid_booking: boolean;
  next_booking: { class_name: string; starts_at: string } | null;
  messages: {
    id: string; sender_kind: "member" | "staff"; sender_name: string | null;
    body: string; created_at: string; attachment_path: string | null;
    attachment_name: string | null; attachment_mime: string | null;
  }[];
};
