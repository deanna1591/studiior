import Link from "next/link";
import { redirect } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { fmtDayLong, fmtTime } from "@/lib/time";
import MessagesView, { type MessageRow } from "./view";

export const dynamic = "force-dynamic";

/**
 * Decision 89 — the member's thread with the studio. One thread per member;
 * the RPC creates it on first open and marks the member's read line. Hidden
 * entirely when the studio has messages switched off.
 */
export default async function Messages() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl, settings } =
    await memberScreen();
  if (!settings.messagesEnabled) redirect("/account");

  const { data } = await supabase.rpc("member_messages", { p_studio_id: ctx.studioId });
  const res = data as { ok?: boolean; thread_id?: string; messages?: RawMessage[] } | null;
  const threadId = res?.thread_id ?? "";
  const raw = res?.ok ? res.messages ?? [] : [];

  // Sign each attachment for an hour. Signing is a Storage call, so do them in
  // one wave rather than in series.
  const signed = await Promise.all(raw.map(async (m) => {
    if (!m.attachment_path) return null;
    const { data: s } = await supabase.storage.from("message-attachments")
      .createSignedUrl(m.attachment_path, 3600);
    return s?.signedUrl ?? null;
  }));

  const messages: MessageRow[] = raw.map((m, i) => ({
    id: m.id,
    mine: m.sender_kind === "member",
    senderName: m.sender_name,
    when: `${fmtDayLong(m.created_at, ctx.timeZone)}, ${fmtTime(m.created_at, ctx.timeZone, ctx.timeFormat)}`,
    body: m.body,
    attachmentUrl: signed[i],
    attachmentName: m.attachment_name,
  }));

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="Messages">
      <Link href="/account" className="m-sub mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">Messages</h1>
      <MessagesView studioId={ctx.studioId} threadId={threadId} messages={messages} />
    </MemberShell>
  );
}

type RawMessage = {
  id: string;
  sender_kind: "member" | "staff";
  sender_name: string | null;
  body: string;
  created_at: string;
  attachment_path: string | null;
  attachment_name: string | null;
};
