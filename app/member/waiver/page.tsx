import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import WaiverSign from "@/components/member/waiver-sign";

export const dynamic = "force-dynamic";

/**
 * Decision 34 — the member signs the studio's current waiver here. The Home
 * banner and the booking gate both send them to this screen.
 */
export default async function WaiverPage() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, memberFullName, avatarUrl } =
    await memberScreen();

  const { data } = await supabase.rpc("current_waiver", { p_studio_id: ctx.studioId });
  const w = data as {
    exists?: boolean; version_id?: string; format?: string; body?: string | null;
    storage_path?: string | null; content_hash?: string; signed?: boolean;
  } | null;

  const pdfUrl = w?.format === "pdf" && w.storage_path
    ? supabase.storage.from("studio-branding").getPublicUrl(w.storage_path).data.publicUrl
    : null;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}
                 title="Studio waiver">
      {!w?.exists ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">{studioName} hasn&rsquo;t provided a waiver yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            Please have a word with the studio — they&rsquo;ll set one up, and then you can
            sign it here.
          </p>
          <Link href="/" className="m-sub mt-3 inline-block text-ink-2 underline">Back to home</Link>
        </div>
      ) : w.signed ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">You&rsquo;ve signed the current waiver.</p>
          <p className="m-sub mt-1 text-ink-2">It&rsquo;s on file with {studioName}.</p>
          <Link href="/" className="m-sub mt-3 inline-block text-ink-2 underline">Back to home</Link>
        </div>
      ) : (
        <>
          <p className="m-sub mb-3 text-ink-2">
            Please read {studioName}&rsquo;s waiver and sign it to confirm your place.
          </p>
          <WaiverSign
            versionId={w.version_id!}
            format={w.format!}
            body={w.body ?? null}
            pdfUrl={pdfUrl}
            memberName={memberFullName || memberName}
          />
        </>
      )}
    </MemberShell>
  );
}
