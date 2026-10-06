// Decision 68 amendment — the member "Scan the studio code" door.
//
// A printed studio QR encodes the member-app URL that opens the check-in
// screen (lib/checkin-url.mjs `checkinUrl`): https://{slug}.{domain}/checkin/{token}.
// When a member scans it in the app, we accept ONLY this studio's own
// member-host check-in URL — the host must be the one the member app is served
// on (passed in as `host`, i.e. window.location.host) and the path must be
// /checkin/{token}. Anything else (another studio's code, a stray QR, a bare
// string) returns null → "That's not this studio's check-in code."
//
// Pure, so the scanner and a node test agree.
export function slugFromCheckinUrl(raw, host) {
  if (typeof raw !== "string" || typeof host !== "string" || !host) return null;
  let u;
  try { u = new URL(raw.trim()); } catch { return null; }
  // Only an http(s) URL on THIS studio's member host.
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  if (u.host.toLowerCase() !== host.toLowerCase()) return null;
  const m = u.pathname.match(/^\/checkin\/([A-Za-z0-9]+)\/?$/);
  return m ? m[1] : null;
}
