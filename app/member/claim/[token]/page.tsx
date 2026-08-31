import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import type { Database } from "@/lib/database.types";
import ClaimForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Taking up an invite. Pre-login, so the lookup runs on a cookie-less anon
 * client — member_invite_preview() is granted to anon for exactly this, and
 * tells the page the studio and first name without exposing the member row.
 */
export default async function Claim({ params }: { params: { token: string } }) {
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("member_invite_preview", { p_token: params.token });
  const inv = Array.isArray(data) ? data[0] : data;

  const slug = currentSlug();

  if (!inv || !inv.valid) {
    return (
      <main className="mx-auto max-w-lg px-5 py-10">
        <h1 className="m-display text-ink">Link no longer works</h1>
        <p className="m-body mt-3 text-ink-2">
          {inv ? "This one has been used or has expired." : "We do not recognise this link."}{" "}
          Ask the studio to send you another — it only takes them a moment.
        </p>
        <a href="/login" className="m-body mt-4 inline-block text-lime-text underline underline-offset-4">
          Or sign in, if you already have an account
        </a>
      </main>
    );
  }

  return (
    <main className="mx-auto max-w-lg px-5 py-10">
      <h1 className="m-display text-ink">Hello {inv.first_name}</h1>
      <p className="m-body mt-2 text-ink-2">
        {inv.studio_name} has set you up. Pick a password and the app is yours —
        your classes, your history and your check-in code.
      </p>
      <ClaimForm token={params.token} email={inv.email ?? ""} slug={slug ?? ""} />
    </main>
  );
}
