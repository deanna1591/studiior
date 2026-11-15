// Decision 107: the lightweight build-id endpoint. The member and instructor apps
// fetch this on load (the baseline) and poll it; a changed id means a new deploy
// is live. It is host-agnostic (the middleware matcher excludes /api), so the
// member host and the staff host both reach it. Dynamic and uncached so a poll
// always sees the running deploy's id.

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// Vercel sets a fresh commit SHA (and deployment id) per deploy. Local dev has
// neither, so it reports "dev" and the prompt never fires there.
const BUILD_ID =
  process.env.VERCEL_GIT_COMMIT_SHA ||
  process.env.VERCEL_DEPLOYMENT_ID ||
  "dev";

export function GET() {
  return new Response(JSON.stringify({ build: BUILD_ID }), {
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
