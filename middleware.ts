import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { createMiddlewareClient } from "@/lib/supabase/middleware";
import { APP_HEADER, SLUG_HEADER, resolveHost } from "@/lib/tenant";
import type { Database } from "@/lib/database.types";

/** Anon client with no cookie access at all — it cannot touch the session. */
function anonClient() {
  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
}

export async function middleware(request: NextRequest) {
  const { app, slug } = resolveHost(request.headers.get("host") ?? "");

  if (app === "member") {
    // Resolve the slug to a real studio before anything renders. Deliberately
    // on a cookie-less anon client: this is a pre-login lookup through
    // studio_by_slug(), the one function anon may execute (migration 004), and
    // it has no business reading or writing anybody's session.
    const { data, error } = await anonClient().rpc("studio_by_slug", { p_slug: slug! });
    if (error || !data || data.length === 0) {
      return new NextResponse(`Unknown studio "${slug}"`, { status: 404 });
    }
  }

  // Pass the resolved tenant to the pages on the REQUEST headers. headers() in
  // a Server Component reads the request, so setting these on the response
  // would never reach a page.
  const forwarded = new Headers(request.headers);
  forwarded.set(APP_HEADER, app);
  if (slug) forwarded.set(SLUG_HEADER, slug);

  // Each host gets its own route subtree without the URL showing it: staff at
  // app.studiior.com/ and a member at reform.studiior.app/ both just see "/".
  const url = request.nextUrl.clone();
  url.pathname = `/${app}${url.pathname === "/" ? "" : url.pathname}`;

  // Refresh the session. Server Components cannot write cookies, so this is
  // where an expiring token gets renewed; the refreshed cookies are copied
  // onto the response actually returned.
  const { supabase, response } = createMiddlewareClient(request);
  await supabase.auth.getUser();

  const rewritten = NextResponse.rewrite(url, { request: { headers: forwarded } });
  response.cookies.getAll().forEach((c) => rewritten.cookies.set(c));
  return rewritten;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|webp)$).*)"],
};
