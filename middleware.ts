import { NextResponse, type NextRequest } from "next/server";
import { createMiddlewareClient } from "@/lib/supabase/middleware";
import { APP_HEADER, SLUG_HEADER, resolveHost } from "@/lib/tenant";

/** Anon client with no cookie access at all — it cannot touch the session. */

export async function middleware(request: NextRequest) {
  const { app, slug } = resolveHost(request.headers.get("host") ?? "");

  // The slug is NOT resolved here any more. It was a Supabase round trip on
  // every single request — including ones that then made the same call again —
  // and the only thing it decided was whether to 404. app/member/layout.tsx
  // already calls studio_by_slug() for the browser-tab title, and the login
  // screen calls it for the studio's branding, so the 404 is raised there on a
  // request that was going to make the call regardless.

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
  //
  // getClaims(), not getUser(). getUser() asks GoTrue over the network on every
  // request — 17-23 ms locally, a quarter of a second from Manila — and this
  // call never reads the answer: nothing here branches on who you are. What it
  // needs is the refresh, which getClaims() performs the same way.
  //
  // It is not getSession() either. getClaims() VERIFIES the signature, locally,
  // with WebCrypto against a cached JWKS. This project signs ES256 on local and
  // on hosted; see assertAsymmetricSigning() in lib/auth.ts for what happens if
  // that ever stops being true.
  const { supabase, response } = createMiddlewareClient(request);
  await supabase.auth.getClaims();

  const rewritten = NextResponse.rewrite(url, { request: { headers: forwarded } });
  response.cookies.getAll().forEach((c) => rewritten.cookies.set(c));
  return rewritten;
}

export const config = {
  // `api` is excluded deliberately. Every other path is rewritten into the
  // host's own subtree, and a Stripe webhook has no tenant host to be rewritten
  // for — it arrives at one fixed URL and resolves its tenant from the signed
  // payload's account field instead.
  matcher: ["/((?!api|_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|webp)$).*)"],
};
