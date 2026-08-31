import QRCode from "qrcode";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import Rotator from "./rotator";

export const dynamic = "force-dynamic";
export const revalidate = 0;

/**
 * The code, and nothing else.
 *
 * Permissions §8 note 13: self check-in is a rotating code presented at the
 * desk. The member never writes a check_in — check_ins has no member insert
 * policy and should not gain one; the desk scans this and creates the row.
 *
 * Rendered server-side as an SVG, so nothing about the code reaches the
 * browser as data and there is no QR library in the client bundle. It is drawn
 * large and at full contrast because it gets held at arm's length across a
 * counter, sometimes in a dark studio.
 */
export default async function CheckIn() {
  const { supabase, studioName, logoUrl } = await memberScreen();

  const { data } = await supabase.rpc("member_checkin_code");
  const row = Array.isArray(data) ? data[0] : data;

  if (!row) {
    return (
      <MemberShell studioName={studioName} logoUrl={logoUrl} title="Check in">
        <p className="m-body text-ink-2">
          We could not make a code for this account. Ask at the desk and they can
          check you in by name.
        </p>
      </MemberShell>
    );
  }

  const svg = await QRCode.toString(row.code, {
    type: "svg",
    errorCorrectionLevel: "M",
    margin: 1,
    color: { dark: "#14170E", light: "#FFFFFF" },
  });

  return (
    <MemberShell studioName={studioName} logoUrl={logoUrl} bare>
      <div className="flex flex-col items-center pt-6">
        <p className="m-sub text-ink-2">Show this at the desk</p>

        <div
          className="mt-4 w-[78vw] max-w-[340px] rounded-2xl border border-line bg-white p-3"
          // The SVG is the whole point of the screen; it scales to the box.
          dangerouslySetInnerHTML={{ __html: svg.replace("<svg", '<svg width="100%" height="100%"') }}
        />

        <p className="m-display mt-5 text-ink">{row.member_name}</p>

        {/* The code in words as well, because a scanner that will not focus in
            a dark studio is a real thing and reading eight characters aloud is
            faster than fetching a manager. */}
        <p className="num mt-1 text-[20px] tracking-[0.18em] text-ink-2">{row.code}</p>

        <Rotator seconds={row.seconds_left} />
      </div>
    </MemberShell>
  );
}
