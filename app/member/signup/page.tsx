import { createServerClient } from "@supabase/ssr";
import { createClient } from "@/lib/supabase/server";
import { currentSlug } from "@/lib/tenant";
import type { Database } from "@/lib/database.types";
import SignupForm from "./form";
import FinishForm from "./finish";

export const dynamic = "force-dynamic";

/**
 * Self signup on the studio's subdomain.
 *
 * Two steps, and the gap between them is the point. Step one makes an account
 * and Supabase emails a confirmation. Step two attaches that account to a
 * member record — and refuses until the address is confirmed, because
 * `members` is unique on (studio_id, email) and an address is therefore enough
 * to name somebody. Auto-linking would hand a stranger who knows an email
 * address that member's attendance and payment history.
 */
export default async function Signup({
  searchParams,
}: {
  searchParams: { sent?: string };
}) {
  const slug = currentSlug();
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data: s } = await anon.rpc("studio_by_slug", { p_slug: slug ?? "" });
  const studio = Array.isArray(s) ? s[0] : s;

  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (user) {
    return (
      <main className="mx-auto max-w-lg px-5 py-10">
        <h1 className="m-head text-[24px] leading-8 text-ink">Almost there</h1>
        <p className="m-body mt-2 text-ink-2">
          {user.email_confirmed_at
            ? `Confirmed. One tap and ${studio?.name ?? "the studio"} is yours.`
            : `We've emailed ${user.email}. Open the link in it, then come back and press the button.`}
        </p>
        <FinishForm studioId={studio?.id ?? ""} confirmed={!!user.email_confirmed_at} />
      </main>
    );
  }

  return (
    <main className="mx-auto max-w-lg px-5 py-10">
      <h1 className="m-head text-[24px] leading-8 text-ink">Join {studio?.name ?? "the studio"}</h1>
      <p className="m-body mt-2 text-ink-2">
        Make an account and you can book a class straight away.
      </p>
      {searchParams.sent && (
        <p className="m-sub mt-4 border-l-[3px] px-3 py-2 text-ink"
           style={{ borderLeftColor: "var(--lime-text)", background: "var(--lime-tint)" }}>
          Check your email for a confirmation link.
        </p>
      )}
      <SignupForm />
      <a href="/login" className="m-body mt-6 inline-block text-lime-text underline underline-offset-4">
        Already have an account? Sign in
      </a>
    </main>
  );
}
