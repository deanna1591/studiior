import { createClient } from "@/lib/supabase/server";

// The subscribable calendar feed (Decision 33 Part B). A calendar app polls this
// URL — it carries NO session, so the token in the path is the whole of the
// authorisation. calendar_feed(token) is SECURITY DEFINER and anon-granted; it
// resolves the hashed token to a person and returns their own future classes as
// text/calendar. An unknown or revoked token comes back null → 404 here.
//
// Served at {slug}.studiior.app/feed/{token} (the middleware rewrites the member
// host to /member/*). Subscribed as webcal://{slug}.studiior.app/feed/{token}.
export const dynamic = "force-dynamic";

export async function GET(_req: Request, { params }: { params: { token: string } }) {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("calendar_feed", { p_token: params.token });
  if (error || !data) return new Response("Not found", { status: 404 });

  return new Response(data as string, {
    headers: {
      "content-type": "text/calendar; charset=utf-8",
      // A feed, not a download: the calendar app fetches it in place. Short cache
      // to blunt a chatty client without hiding a change for long (the SQL side
      // caches 5 min too).
      "cache-control": "public, max-age=300",
    },
  });
}
