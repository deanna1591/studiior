import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import PreferencesForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Where the unsubscribe link in every email lands.
 *
 * Transactional mail is exempt from unsubscribe rules and three of our templates
 * cannot be switched off at all — but a member who cannot find a way to turn
 * anything off marks the message as spam instead, and those complaints land
 * against a sending domain shared by every studio. One member's annoyance
 * degrades delivery for all of them.
 */
export default async function Settings() {
  const { ctx, supabase, studioName, logoUrl, preset, accent , openOffers, memberName, avatarUrl} = await memberScreen();

  const { data: prefs } = await supabase
    .from("notification_preferences")
    .select("booking_email, reminder_email, waitlist_email, credit_expiry_email, milestone_email")
    .eq("member_id", ctx.memberId)
    .maybeSingle();

  // No row means defaults, and every default is on — the same reading
  // notification_wanted() takes in SQL. The screen must not show a member as
  // opted out of something they were never asked about.
  const on = (v: boolean | null | undefined) => v ?? true;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}
                 title="Email settings">
      <p className="m-sub mb-5 text-ink-2">
        Choose what {studioName} emails you about. You can change this whenever
        you like.
      </p>

      <PreferencesForm
        initial={{
          booking_email: on(prefs?.booking_email),
          reminder_email: on(prefs?.reminder_email),
          waitlist_email: on(prefs?.waitlist_email),
          credit_expiry_email: on(prefs?.credit_expiry_email),
          milestone_email: on(prefs?.milestone_email),
        }}
      />

      <section className="mt-8 border-t border-line pt-5">
        <h2 className="section-label text-ink-2">Always sent</h2>
        <p className="m-sub mt-2 text-ink-2">
          Some emails go out whatever you choose here, because you would be left
          standing outside a locked door without them:
        </p>
        <ul className="m-sub mt-2 space-y-1 text-ink-2">
          <li>· A class you are booked into is cancelled</li>
          <li>· Someone else is teaching a class you are booked into</li>
          <li>· A payment did not go through</li>
          <li>· A message written to you by someone at the studio</li>
        </ul>
      </section>

      <Link href="/account" className="m-sub mt-8 block text-ink-2 underline">
        Back to your account
      </Link>
    </MemberShell>
  );
}
