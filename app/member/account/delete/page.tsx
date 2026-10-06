import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import DeleteAccountForm from "@/components/member/delete-account-form";
import { DELETE_CONSEQUENCES } from "@/lib/account-delete";

export const dynamic = "force-dynamic";

/**
 * Decision 69 — the member's account-deletion screen (login required). Also the
 * public URL named in the Play Data Safety form:
 * https://{slug}.studiior.app/account/delete. Plain-language consequences, a
 * typed DELETE, a destructive button. A login that is also studio staff/an
 * instructor is refused by the RPC (handled in the form).
 */
export default async function DeleteAccount() {
  const { studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl, settings } =
    await memberScreen();

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-2 text-ink">Delete your account</h1>
      <p className="m-sub mb-4 text-ink-2">
        This removes your account from {studioName}. Please read what happens before you confirm.
      </p>

      <ul className="m-card space-y-2.5 p-4">
        {DELETE_CONSEQUENCES.map((c) => (
          <li key={c} className="m-sub flex items-start gap-2.5 text-ink">
            <span aria-hidden className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full"
                  style={{ background: "var(--coral)" }} />
            {c}
          </li>
        ))}
      </ul>

      <DeleteAccountForm contactEmail={settings.studioContactEmail} />
    </MemberShell>
  );
}
