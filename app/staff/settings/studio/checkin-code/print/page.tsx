import Link from "next/link";
import QRCode from "qrcode";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { staffMemberOrigin } from "@/lib/member-urls-server";
import { checkinUrl } from "@/lib/checkin-url";
import RemintCode from "../remint";

export const dynamic = "force-dynamic";

/**
 * Decision 35 §3 — the printable studio check-in code. The owner prints this
 * and puts it on the wall; a member scans it to open the app and check in. The
 * slug is minted lazily here (ensure_checkin_slug) so a studio that never
 * prints never gets one. @media print hides everything but the code.
 */
export default async function CheckinCodePrint() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Check-in code"><Denied what="the check-in code" role={ctx.role} /></AppShell>;
  }

  const [{ data: studio }, { data: slug }] = await Promise.all([
    supabase.from("studios").select("slug, name, logo_url").eq("id", ctx.studioId).maybeSingle(),
    supabase.rpc("ensure_checkin_slug", { p_studio_id: ctx.studioId }),
  ]);

  const origin = await staffMemberOrigin(supabase, studio?.slug ?? "");
  const url = slug ? checkinUrl(origin, slug as string) : null;
  const qrSvg = url
    ? await QRCode.toString(url, {
        type: "svg", margin: 1, errorCorrectionLevel: "M",
        color: { dark: "#1A1512", light: "#FFFFFF" },
      })
    : null;

  return (
    <AppShell {...shell} title="Check-in code">
      {/* Only the code area prints; the rail, the header and the controls do not. */}
      <style>{`
        @media print {
          .no-print { display: none !important; }
          body, main { background: #fff !important; }
        }
      `}</style>

      <Link href="/settings/studio" className="no-print mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">
        ← Studio
      </Link>

      <p className="no-print mb-4 max-w-2xl text-[13px] leading-[19px] text-ink-3">
        Print this and put it where members arrive. Scanning it opens the app and
        checks them in — inside the class window, from the studio. Re-minting makes
        a new code and the old printout stops working.
      </p>

      <section className="mx-auto max-w-sm rounded-2xl border border-line bg-surface px-6 py-8 text-center">
        {studio?.logo_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={studio.logo_url} alt="" className="mx-auto mb-4 h-14 w-14 rounded-xl object-contain" />
        ) : null}
        <p className="text-[20px] font-semibold leading-7 text-ink">{studio?.name ?? "Check in"}</p>
        {qrSvg ? (
          <div className="mx-auto mt-5 w-[260px]"
               dangerouslySetInnerHTML={{ __html: qrSvg.replace("<svg", '<svg width="100%" height="100%"') }} />
        ) : (
          <p className="mt-5 text-[14px] text-ink-2">Set up your member app domain first.</p>
        )}
        <p className="mt-5 text-[15px] font-medium text-ink">Scan to check in</p>
      </section>

      <RemintCode />
    </AppShell>
  );
}
