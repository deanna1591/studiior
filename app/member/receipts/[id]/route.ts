import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";
import { formatMoney } from "@/lib/plans";
import { fmtDayLong } from "@/lib/time";
import { receiptMethod } from "@/lib/wallet";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Decision 88 slice B — a receipt PDF for a member's own payment, generated on
// demand with pdf-lib. Member session only, own payments only (payments_self
// RLS makes any other payment invisible → 403). No invoice number beyond the
// payment id; the studio accent draws the heading rule.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function hexRgb(hex: string | null) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex ?? "");
  if (!m) return rgb(0.09, 0.09, 0.08); // ink fallback
  const n = parseInt(m[1], 16);
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
}

export async function GET(_req: Request, { params }: { params: { id: string } }) {
  const paymentId = params.id.replace(/\.pdf$/i, "");
  if (!UUID.test(paymentId)) return new Response("Not found", { status: 404 });

  const supabase = createClient();

  // payments_self scopes to the member's own rows; a payment that is not theirs
  // (or does not exist) is simply invisible, so an empty read is a refusal.
  const { data: p } = await supabase
    .from("payments")
    .select(`
      id, studio_id, member_id, amount_cents, currency, provider, method, paid_at, created_at, description,
      memberships(membership_plans(name)),
      product_orders(products(name)),
      bookings(class_occurrences(name, class_types(name))),
      group_purchases(membership_plans(name))
    `)
    .eq("id", paymentId)
    .maybeSingle();
  if (!p) return new Response("Not your payment", { status: 403 });

  const [{ data: studio }, { data: member }] = await Promise.all([
    supabase.from("studios").select("name, logo_url, accent_color, timezone").eq("id", p.studio_id).maybeSingle(),
    supabase.from("members").select("first_name, last_name").eq("id", p.member_id ?? "").maybeSingle(),
  ]);

  const tz = studio?.timezone ?? "UTC";
  const anyP = p as any;
  const item: string =
    anyP.memberships?.membership_plans?.name
    ?? anyP.product_orders?.products?.name
    ?? anyP.bookings?.class_occurrences?.name
    ?? anyP.bookings?.class_occurrences?.class_types?.name
    ?? anyP.group_purchases?.membership_plans?.name
    ?? (p.description || "Payment");
  const memberName = [member?.first_name, member?.last_name].filter(Boolean).join(" ") || "Member";
  const when = fmtDayLong(p.paid_at ?? p.created_at, tz);

  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595, 842]);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const ink = rgb(0.09, 0.09, 0.08);
  const grey = rgb(0.42, 0.42, 0.4);
  const accent = hexRgb(studio?.accent_color ?? null);
  const left = 56;
  const width = 595 - left * 2;

  // Header: the studio's logo if we can fetch it, otherwise its name.
  let headerBottom = 786;
  let drewLogo = false;
  if (studio?.logo_url) {
    try {
      const res = await fetch(studio.logo_url);
      if (res.ok) {
        const bytes = new Uint8Array(await res.arrayBuffer());
        const img = await pdf.embedPng(bytes).catch(() => pdf.embedJpg(bytes));
        const h = 40;
        const w = (img.width / img.height) * h;
        page.drawImage(img, { x: left, y: 786 - h, width: Math.min(w, 200), height: h });
        headerBottom = 786 - h;
        drewLogo = true;
      }
    } catch { /* no logo — fall through to the name */ }
  }
  if (!drewLogo) {
    page.drawText(studio?.name ?? "Studio", { x: left, y: 764, size: 18, font: bold, color: ink });
    headerBottom = 760;
  }

  page.drawText("Receipt", { x: left, y: headerBottom - 34, size: 24, font: bold, color: ink });
  page.drawRectangle({ x: left, y: headerBottom - 46, width, height: 2, color: accent });

  const fields: [string, string][] = [
    ["Member", memberName],
    ["Date", when],
    ["Item", item],
    ["Amount", formatMoney(p.amount_cents, p.currency)],
    ["Payment method", receiptMethod(p.provider as string | null, p.method as string | null)],
    ["Payment ID", p.id],
  ];
  let y = headerBottom - 86;
  for (const [label, value] of fields) {
    page.drawText(label.toUpperCase(), { x: left, y, size: 9, font, color: grey });
    page.drawText(value, { x: left, y: y - 16, size: 12, font: bold, color: ink });
    y -= 40;
  }

  const bytes = await pdf.save();
  return new Response(Buffer.from(bytes), {
    headers: {
      "content-type": "application/pdf",
      "content-disposition": `inline; filename="receipt-${p.id}.pdf"`,
      "cache-control": "private, no-store",
    },
  });
}
