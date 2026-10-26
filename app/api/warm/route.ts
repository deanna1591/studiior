export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 82 — keep the member host's entry lambdas warm.
 *
 * A Vercel cron (vercel.json) hits this; it makes a real HTTP request to the
 * member host's /login and /instructor/login, which invokes — and so keeps warm
 * — those serverless functions. Members are in Manila and the functions run in
 * iad1; a cold start was measured at ~4 s.
 *
 * NOTE: the project is on Vercel's Hobby plan, which allows a cron at most ONCE
 * PER DAY (a sub-daily schedule is rejected at deploy), so this runs daily and
 * does NOT keep functions warm through the day — it only exercises the path. The
 * real fix for cold starts is Pro + Fluid Compute / minimum instances; see
 * Decision 82. The endpoint is kept so the warm path is ready the moment the
 * plan allows a frequent schedule.
 *
 * It fetches FIXED URLs (the configured member origin's login pages), never
 * anything from the request, so there is no SSRF surface; and it only GETs
 * public pages, so it needs no auth and has no side effects.
 */
export async function GET() {
  const origin = process.env.WARM_MEMBER_ORIGIN || "https://reformcollective.studiior.app";
  const targets = [`${origin}/login`, `${origin}/instructor/login`];
  const results = await Promise.allSettled(
    targets.map((u) => fetch(u, { headers: { "x-studiior-warm": "1" }, cache: "no-store" })),
  );
  const warmed = results.map((r, i) => ({
    target: targets[i],
    ok: r.status === "fulfilled" && r.value.ok,
    status: r.status === "fulfilled" ? r.value.status : "error",
  }));
  return Response.json({ warmed }, { headers: { "Cache-Control": "no-store" } });
}
