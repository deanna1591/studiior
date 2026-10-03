import { createServerClient } from "@supabase/ssr";
import type { Database } from "@/lib/database.types";

export const dynamic = "force-dynamic";

/**
 * Decision 50 — the one-tap unsubscribe, for a signed-out person.
 *
 * Pre-login, so the call runs on a cookie-less anon client; unsubscribe_marketing
 * is granted to anon for exactly this, resolves the token to the member, turns
 * marketing consent off and returns the STUDIO name only (never the member's).
 * Booking, reminder and waitlist mail are untouched. No "Studiior" anywhere.
 */
export default async function Unsubscribe({ params }: { params: { token: string } }) {
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );

  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  let studio: string | null = null;
  let valid = false;
  if (uuid.test(params.token)) {
    const { data, error } = await anon.rpc("unsubscribe_marketing", { p_token: params.token });
    const row = Array.isArray(data) ? data[0] : data;
    if (!error && row) { valid = true; studio = row.studio_name; }
  }

  return (
    <main className="mx-auto max-w-lg px-5 py-12">
      {valid ? (
        <>
          <h1 className="m-head text-[24px] leading-8 text-ink">You’re unsubscribed</h1>
          <p className="m-body mt-3 text-ink-2">
            You’ve been unsubscribed from {studio} news. Booking emails still arrive.
          </p>
        </>
      ) : (
        <>
          <h1 className="m-head text-[24px] leading-8 text-ink">Link not valid</h1>
          <p className="m-body mt-3 text-ink-2">This link isn’t valid.</p>
        </>
      )}
    </main>
  );
}
