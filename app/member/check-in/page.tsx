import QRCode from "qrcode";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import Rotator from "./rotator";
import DoorScan from "@/components/member/door-scan";

export const dynamic = "force-dynamic";
export const revalidate = 0;

/**
 * The Check-in tab — two doors (Decision 68 amendment).
 *
 * "Check in now" on the class row is the primary path; this tab is the fallback.
 *
 * 1. Scan the studio code — the camera opens ON TAP (never on page load),
 *    decodes the printed studio QR and runs the same /checkin/{slug} flow
 *    (window + geofence + reason sentences) in-app. See components/member/door-scan.
 * 2. Show my code — the personal rotating QR (Permissions §8 note 13: the member
 *    never writes a check_in; the desk/instructor scans this and creates the
 *    row), with the 8-character code in large type beneath it. Rendered
 *    server-side as an SVG, so the code never reaches the browser as data and
 *    there is no QR library in the client bundle.
 */
export default async function CheckIn() {
  const { supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } = await memberScreen();

  const { data } = await supabase.rpc("member_checkin_code");
  const row = Array.isArray(data) ? data[0] : data;

  const svg = row
    ? await QRCode.toString(row.code, {
        type: "svg", errorCorrectionLevel: "M", margin: 1,
        color: { dark: "#14170E", light: "#FFFFFF" },
      })
    : null;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="Check in">
      <p className="m-sub mb-4 text-ink-2">
        The quickest way is the <span className="font-medium text-ink">Check in now</span> button on your
        class. Here are the two doors if you need them.
      </p>

      {/* Door 1 — scan the printed studio code (camera on tap). */}
      <DoorScan />

      {/* Door 2 — show my code for the desk or an instructor to scan. */}
      <div className="m-card mt-3 p-4">
        <p className="text-[16px] font-semibold text-ink">Show my code</p>
        <p className="m-sub mt-0.5 text-ink-2">For the front desk or an instructor to scan or type.</p>

        {row && svg ? (
          <div className="mt-4 flex flex-col items-center">
            <div
              className="w-[70vw] max-w-[300px] rounded-xl bg-white p-3"
              dangerouslySetInnerHTML={{ __html: svg.replace("<svg", '<svg width="100%" height="100%"') }}
            />
            <p className="m-head mt-4 text-[20px] leading-7 text-ink">{row.member_name}</p>
            {/* The code in words as well, because a scanner that will not focus
                in a dark studio is a real thing and reading eight characters
                aloud is faster than fetching a manager. */}
            <p className="num mt-1 text-[22px] tracking-[0.2em] text-ink-2">{row.code}</p>
            <Rotator seconds={row.seconds_left} />
          </div>
        ) : (
          <p className="m-body mt-3 text-ink-2">
            We could not make a code for this account. Ask at the desk and they can check you in by name.
          </p>
        )}
      </div>
    </MemberShell>
  );
}
