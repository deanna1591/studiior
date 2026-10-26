export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 82 — the member host's service worker, served here so it bypasses
 * the host rewrite (middleware excludes `sw.js`, as it does `.well-known`) and
 * carries the DEPLOY'S COMMIT SHA in its cache name. A new deploy => a new SW
 * body => the browser installs it => activate purges every old cache, so no
 * stale JS can survive a deploy.
 *
 * It is deliberately the most conservative SW possible: cache-first ONLY for
 * immutable, content-hashed static assets (/_next/static and same-origin
 * script/style/font/image), and NETWORK PASS-THROUGH for everything else —
 * navigations, RSC and data go straight to the network, so nothing personal is
 * ever cached and a bad cache can never trap a member on stale content. The win
 * is that a second navigation re-uses the ~90 kB of cached chunks instead of
 * re-downloading them over a phone network.
 *
 * Registered only from the member layout (app/member/layout.tsx), so the staff
 * host never activates it even though this route serves on both.
 */
export function GET() {
  const version =
    process.env.VERCEL_GIT_COMMIT_SHA ||
    process.env.VERCEL_DEPLOYMENT_ID ||
    "dev";

  const body = `/* studiior member service worker */
const VERSION = ${JSON.stringify(version)};
const CACHE = "studiior-shell-" + VERSION;

self.addEventListener("install", function () { self.skipWaiting(); });

self.addEventListener("activate", function (e) {
  e.waitUntil((async function () {
    const keys = await caches.keys();
    await Promise.all(keys.map(function (k) { return k === CACHE ? null : caches.delete(k); }));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", function (e) {
  const req = e.request;
  if (req.method !== "GET") return;
  let url;
  try { url = new URL(req.url); } catch (err) { return; }
  if (url.origin !== self.location.origin) return;

  const isStatic = url.pathname.indexOf("/_next/static/") === 0;
  const isAsset = req.destination === "style" || req.destination === "script" ||
                  req.destination === "font" || req.destination === "image";

  // Cache-first ONLY for immutable / static assets — never a navigation or data
  // response (those carry personal content and must stay fresh). Everything else
  // is left to the browser's normal network path.
  if (isStatic || isAsset) {
    e.respondWith((async function () {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res && res.ok && res.type === "basic") { cache.put(req, res.clone()); }
      return res;
    })());
  }
});
`;

  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "text/javascript; charset=utf-8",
      "Service-Worker-Allowed": "/",
      // Re-fetched on each load so a new deploy's SW is picked up at once.
      "Cache-Control": "no-cache, no-store, must-revalidate",
    },
  });
}
