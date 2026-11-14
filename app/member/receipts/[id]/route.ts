import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { createClient } from "@/lib/supabase/server";
import { formatMoney } from "@/lib/plans";
import { fmtDayLong } from "@/lib/time";
import { receiptMethod } from "@/lib/wallet";
import { hasInvoiceDetails, invoiceMethod } from "@/lib/invoice";
import {
  buildInvoicePdf, INVOICE_FONT_FILES, type InvoiceFontKey, type InvoiceData,
} from "@/lib/invoice-pdf";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Decision 88 (c) — the download for a member's own payment. When the studio
// has filled Settings → Studio → Invoice details it is a BIR Service Invoice
// (numbered, VAT-inclusive); otherwise it is the plain receipt as slice B.
// Member session only, own payments only (payments_self RLS → any other payment
// is invisible → 403). STEP-0 fix: served as `attachment` (the installed PWA /
// iOS renders an inline PDF as a blank screen), and the logo fetch is bounded.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function hexRgb(hex: string | null) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex ?? "");
  if (!m) return rgb(0.09, 0.09, 0.08);
  const n = parseInt(m[1], 16);
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
}

// Fetch the studio logo with a short timeout; a slow cross-region storage fetch
// must never hang the function (that was half of the blank-page bug).
async function fetchBounded(url: string, ms = 4000): Promise<Uint8Array | null> {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), ms);
    const res = await fetch(url, { signal: ctl.signal }).finally(() => clearTimeout(t));
    if (!res.ok) return null;
    return new Uint8Array(await res.arrayBuffer());
  } catch {
    return null;
  }
}

// The invoice fonts: the bundled copy (outputFileTracingIncludes) first, else
// the public CDN — so the route works whether or not public/ was traced in.
async function loadInvoiceFonts(reqUrl: string): Promise<Record<InvoiceFontKey, Uint8Array> | null> {
  const dir = join(process.cwd(), "public", "fonts", "invoice");
  const out = {} as Record<InvoiceFontKey, Uint8Array>;
  for (const [key, file] of Object.entries(INVOICE_FONT_FILES) as [InvoiceFontKey, string][]) {
    let bytes: Uint8Array | null = null;
    try { bytes = new Uint8Array(await readFile(join(dir, file))); } catch { /* not bundled */ }
    if (!bytes) bytes = await fetchBounded(new URL(`/fonts/invoice/${file}`, reqUrl).toString(), 6000);
    if (!bytes) return null;
    out[key] = bytes;
  }
  return out;
}

export async function GET(req: Request, { params }: { params: { id: string } }) {
  const paymentId = params.id.replace(/\.pdf$/i, "");
  if (!UUID.test(paymentId)) return new Response("Not found", { status: 404 });

  const supabase = createClient();

  const { data: p } = await supabase
    .from("payments")
    .select(`
      id, studio_id, member_id, amount_cents, currency, provider, method, status,
      refunded_cents, refunded_at, invoice_no, received_by, reference, paid_at, created_at, description,
      memberships(membership_plans(name)),
      product_orders(products(name)),
      bookings(class_occurrences(name, class_types(name))),
      group_purchases(membership_plans(name))
    `)
    .eq("id", paymentId)
    .maybeSingle();
  if (!p) return new Response("Not your payment", { status: 403 });

  const [{ data: studio }, { data: member }, { data: inv }] = await Promise.all([
    supabase.from("studios").select("name, logo_url, accent_color, timezone").eq("id", p.studio_id).maybeSingle(),
    supabase.from("members").select("first_name, last_name, email").eq("id", p.member_id ?? "").maybeSingle(),
    // Members cannot read studio_settings under RLS; a definer serves the
    // studio's invoice identity to its own members.
    supabase.rpc("studio_invoice_details", { p_studio_id: p.studio_id }),
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
  const whenIso = p.paid_at ?? p.created_at;
  const when = fmtDayLong(whenIso, tz);
  const settings = (inv ?? null) as any;

  // Decision 103a: a reservation credit applied to this Xendit purchase (the
  // amount paid is already net of it). Shown on the receipt. Members read their
  // own xendit_purchases under RLS; joined on xendit_payment_id = reference.
  let appliedCredit = 0;
  if (p.provider === "xendit" && p.reference) {
    const { data: xp } = await supabase
      .from("xendit_purchases")
      .select("credit_applied_cents")
      .eq("member_id", p.member_id ?? "")
      .eq("xendit_payment_id", p.reference)
      .maybeSingle();
    appliedCredit = ((xp as any)?.credit_applied_cents as number | null) ?? 0;
  }

  let bytes: Uint8Array;
  let name: string;

  if (hasInvoiceDetails(settings)) {
    // A BIR invoice. Ensure the payment carries a number (the trigger numbers
    // new payments; a pre-existing one is numbered lazily on first download).
    let invoiceNo = p.invoice_no as string | null;
    if (!invoiceNo) {
      const { data: assigned } = await supabase.rpc("assign_invoice_no", { p_payment_id: p.id });
      invoiceNo = (assigned as string | null) ?? null;
    }
    const fonts = await loadInvoiceFonts(req.url);
    if (invoiceNo && fonts) {
      const refunded = p.refunded_cents ?? 0;
      // Show the gross price, then the reservation credit as a deduction, so the
      // total still equals what was paid (amount_cents, already net of credit).
      const items: InvoiceData["items"] = [{ desc: item, qty: 1, price: p.amount_cents + appliedCredit }];
      if (appliedCredit > 0) items.push({ desc: "Reservation credit applied", qty: 1, price: -appliedCredit });
      if (refunded > 0) items.push({ desc: "Refund", qty: 1, price: -refunded });
      const data: InvoiceData = {
        seller: {
          name: settings.invoice_registered_name ?? studio?.name ?? "Studio",
          proprietor: settings.invoice_proprietor,
          tin: settings.invoice_tin,
          addressLines: String(settings.invoice_address ?? "").split(/\r?\n/).map((l: string) => l.trim()).filter(Boolean),
          email: settings.invoice_email,
          landline: settings.invoice_landline,
          mobile: settings.invoice_mobile,
          atpNo: settings.invoice_atp_no,
          atpDate: settings.invoice_atp_date,
          series: settings.invoice_series,
          vatRate: Number(settings.invoice_vat_rate ?? 12),
        },
        logo: studio?.logo_url ? await fetchBounded(studio.logo_url) : null,
        invoiceNo,
        date: when,
        client: { name: memberName, email: member?.email ?? null, ref: p.id.slice(0, 8).toUpperCase() },
        items,
        method: invoiceMethod(p.provider as string | null, p.method as string | null),
        paymentRef: (p.reference as string | null) ?? null,
        amountReceivedCents: p.amount_cents - refunded,
        receivedBy: (p.received_by as string | null) ?? null,
        paid: p.status === "succeeded" || refunded > 0,
      };
      bytes = await buildInvoicePdf(data, fonts);
      name = `invoice-${invoiceNo.replace(/\D/g, "") || p.id}.pdf`;
      return pdfResponse(bytes, name);
    }
    // Could not number or load fonts — fall through to the plain receipt rather
    // than fail the download.
  }

  // Plain receipt (slice B).
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595, 842]);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const ink = rgb(0.09, 0.09, 0.08);
  const grey = rgb(0.42, 0.42, 0.4);
  const accent = hexRgb(studio?.accent_color ?? null);
  const left = 56;
  const width = 595 - left * 2;

  let headerBottom = 786;
  const logoBytes = studio?.logo_url ? await fetchBounded(studio.logo_url) : null;
  let drewLogo = false;
  if (logoBytes) {
    try {
      const img = await pdf.embedPng(logoBytes).catch(() => pdf.embedJpg(logoBytes));
      const h = 40;
      const w = (img.width / img.height) * h;
      page.drawImage(img, { x: left, y: 786 - h, width: Math.min(w, 200), height: h });
      headerBottom = 786 - h;
      drewLogo = true;
    } catch { /* fall through to the name */ }
  }
  if (!drewLogo) {
    page.drawText((studio?.name ?? "Studio").replace(/[^\u0000-ÿ]/g, ""), { x: left, y: 764, size: 18, font: bold, color: ink });
    headerBottom = 760;
  }

  page.drawText("Receipt", { x: left, y: headerBottom - 34, size: 24, font: bold, color: ink });
  page.drawRectangle({ x: left, y: headerBottom - 46, width, height: 2, color: accent });

  // Helvetica is WinAnsi; strip anything it cannot encode (a currency symbol
  // like ₱ or €, a non-Latin name) so a draw never throws. The amount keeps its
  // value by swapping a leading symbol for the currency code.
  const win = (s: string) => s.replace(/[^\u0000-ÿ]/g, "");
  const fields: [string, string][] = [
    ["Member", win(memberName)],
    ["Date", win(when)],
    ["Item", win(item)],
    ["Amount", win(formatMoney(p.amount_cents, p.currency).replace(/[^\u0000-ÿ]\s*/, `${p.currency} `))],
    ...(appliedCredit > 0
      ? [["Reservation credit applied", win(formatMoney(appliedCredit, p.currency).replace(/[^\u0000-ÿ]\s*/, `${p.currency} `))] as [string, string]]
      : []),
    ["Payment method", receiptMethod(p.provider as string | null, p.method as string | null)],
    ["Payment ID", p.id],
  ];
  let y = headerBottom - 86;
  for (const [label, value] of fields) {
    page.drawText(label.toUpperCase(), { x: left, y, size: 9, font, color: grey });
    page.drawText(value, { x: left, y: y - 16, size: 12, font: bold, color: ink });
    y -= 40;
  }

  bytes = await pdf.save();
  name = `receipt-${p.id}.pdf`;
  return pdfResponse(bytes, name);
}

function pdfResponse(bytes: Uint8Array, filename: string) {
  return new Response(Buffer.from(bytes), {
    headers: {
      "content-type": "application/pdf",
      // attachment, not inline: the installed PWA / iOS renders an inline PDF
      // as a blank screen; a download works everywhere.
      "content-disposition": `attachment; filename="${filename}"`,
      "cache-control": "private, no-store",
    },
  });
}
