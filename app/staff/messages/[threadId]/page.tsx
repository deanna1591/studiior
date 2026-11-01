import Link from "next/link";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { fmtDayLong, fmtTime } from "@/lib/time";
import StaffReply from "../reply";

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

  // Sign the attachments (the private message-attachments bucket), one wave.
  const signed = await Promise.all((t.messages ?? []).map(async (m) => {
    if (!m.attachment_path) return null;
    const { data: s } = await supabase.storage.from("message-attachments").createSignedUrl(m.attachment_path, 3600);
    return s?.signedUrl ?? null;
  }));

  const next = t.next_booking;

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
      </div>

      <ul className="mt-4 max-w-2xl space-y-3">
        {(t.messages ?? []).map((m, i) => {
          const fromStudio = m.sender_kind === "staff";
          return (
            <li key={m.id} className={fromStudio ? "flex justify-end" : "flex justify-start"}>
              <div className="max-w-[80%] rounded-2xl px-3.5 py-2.5"
                   style={fromStudio
                     ? { background: "var(--accent-chip)", color: "var(--ink)" }
                     : { background: "var(--surface)", border: "1px solid var(--line)" }}>
                <p className="mb-0.5 text-[11px] text-ink-3">
                  {fromStudio ? (m.sender_name ?? "Studio") : t.member_name} · {fmtDayLong(m.created_at, ctx.timeZone)} · {fmtTime(m.created_at, ctx.timeZone, ctx.timeFormat)}
                </p>
                <p className="whitespace-pre-line text-[13px] leading-[19px] text-ink">{m.body}</p>
                {signed[i] && (
                  <a href={signed[i]!} target="_blank" rel="noopener noreferrer"
                     className="mt-1.5 inline-block text-[12px] text-ink-2 underline underline-offset-4">
                    {m.attachment_name ?? "Attachment"}
                  </a>
                )}
              </div>
            </li>
          );
        })}
      </ul>

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
    body: string; created_at: string; attachment_path: string | null; attachment_name: string | null;
  }[];
};
