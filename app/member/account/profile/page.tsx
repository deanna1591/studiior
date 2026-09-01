import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import ProfileForm from "./form";

export const dynamic = "force-dynamic";

/**
 * The member's own details.
 *
 * Everything on this screen is inside the set migration 035's trigger lets a
 * member change. The things that are NOT — their status, their waiver, their
 * visit count, their health band — are absent rather than shown disabled,
 * because a disabled field is a promise that it might one day be editable here,
 * and none of these should be.
 */
export default async function Profile() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data: me } = await supabase
    .from("members")
    .select("first_name, preferred_name, phone, emergency_contact")
    .eq("id", ctx.memberId)
    .maybeSingle();

  const ec = (me?.emergency_contact ?? {}) as { name?: string; phone?: string };

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-5 text-ink">Your details</h1>

      <ProfileForm
        name={me?.first_name ?? ""}
        avatarUrl={avatarUrl}
        preferredName={me?.preferred_name ?? ""}
        phone={me?.phone ?? ""}
        emergencyName={ec.name ?? ""}
        emergencyPhone={ec.phone ?? ""}
      />
    </MemberShell>
  );
}
