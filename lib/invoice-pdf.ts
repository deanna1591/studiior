// Decision 88 (c) — the BIR Service Invoice, drawn with pdf-lib, following the
// layout and colours of docs/invoice-reference/rpc_invoice.py (A4, the pink/
// black accent bars, the seller block, the Sold-to box, a five-row items table,
// the VAT-inclusive 12% tax summary, the payment-method chips, the PAID stamp
// and the ATP footer). Fonts are the vendored Google Fonts under
// public/fonts/invoice (Space Grotesk, Space Mono, Bodoni Moda; SIL OFL).
import { PDFDocument, PDFFont, PDFPage, rgb, degrees, type RGB } from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import { computeInvoice, pesoStr, type InvoiceItem } from "@/lib/invoice";

export type InvoiceFontKey = "SG" | "SGM" | "SGB" | "BM" | "BMI" | "MONO" | "MONOB";
export const INVOICE_FONT_FILES: Record<InvoiceFontKey, string> = {
  SG: "SpaceGrotesk-Regular.ttf",
  SGM: "SpaceGrotesk-Medium.ttf",
  SGB: "SpaceGrotesk-Bold.ttf",
  BM: "BodoniModa-Regular.ttf",
  BMI: "BodoniModa-Italic.ttf",
  MONO: "SpaceMono-Regular.ttf",
  MONOB: "SpaceMono-Bold.ttf",
};

export type InvoiceData = {
  seller: {
    name: string;
    proprietor?: string | null;
    tin?: string | null;
    addressLines: string[];
    email?: string | null;
    landline?: string | null;
    mobile?: string | null;
    atpNo?: string | null;
    atpDate?: string | null;
    series?: string | null;
    vatRate: number;
  };
  logo?: Uint8Array | null;
  invoiceNo: string;
  date: string;
  client: { name: string; ref?: string | null; email?: string | null };
  items: InvoiceItem[]; // price in cents
  method: string; // Cash | GCash | Maya | Card | Bank Transfer
  paymentRef?: string | null;
  amountReceivedCents: number;
  receivedBy?: string | null;
  paid: boolean;
};

const PINK = hex("#F5066B");
const BLUSH = hex("#FFD3E6");
const PEARL = hex("#F5F3F4");
const BLACK = hex("#000000");
const PEWTER = hex("#8A8889");
const WHITE = hex("#FFFFFF");
const LINE = hex("#E2DDDF");
const ROWALT = hex("#FBF9FA");

function hex(h: string): RGB {
  const n = parseInt(h.slice(1), 16);
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
}

const W = 595.28;
const H = 841.89;
const M = 40;

type Align = "l" | "c" | "r";

export async function buildInvoicePdf(
  d: InvoiceData,
  fonts: Record<InvoiceFontKey, Uint8Array>,
): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  pdf.setTitle("Service Invoice");
  pdf.setAuthor(d.seller.name);

  const load = (bytes: Uint8Array) => pdf.embedFont(bytes, { subset: true });
  const SG = await load(fonts.SG);
  const SGM = await load(fonts.SGM);
  const SGB = await load(fonts.SGB);
  const BM = await load(fonts.BM);
  const BMI = await load(fonts.BMI);
  const MONO = await load(fonts.MONO);
  const MONOB = await load(fonts.MONOB);

  const page = pdf.addPage([W, H]);

  // Some vendored glyphs are missing (e.g. Bodoni lacks ₱); strip anything the
  // chosen font cannot encode so a draw never throws mid-page.
  const safe = (font: PDFFont, s: string) => {
    let out = "";
    for (const ch of s) {
      try { font.widthOfTextAtSize(ch, 10); out += ch; } catch { out += " "; }
    }
    return out;
  };
  const text = (x: number, y: number, s: string, font: PDFFont, size: number, color: RGB, align: Align = "l") => {
    const str = safe(font, s);
    let tx = x;
    if (align !== "l") {
      const w = font.widthOfTextAtSize(str, size);
      tx = align === "r" ? x - w : x - w / 2;
    }
    page.drawText(str, { x: tx, y, size, font, color });
  };
  const label = (x: number, y: number, s: string, color: RGB = PEWTER, align: Align = "l", size = 6.5) =>
    text(x, y, s.toUpperCase(), MONOB, size, color, align);
  const fill = (x: number, y: number, w: number, h: number, color: RGB) =>
    page.drawRectangle({ x, y, width: w, height: h, color });
  const stroke = (x: number, y: number, w: number, h: number, color: RGB, thickness = 0.7) =>
    page.drawRectangle({ x, y, width: w, height: h, borderColor: color, borderWidth: thickness });
  const hline = (x1: number, x2: number, y: number, color: RGB, thickness = 0.6, dash?: number[]) =>
    page.drawLine({ start: { x: x1, y }, end: { x: x2, y }, thickness, color, dashArray: dash });
  const vline = (x: number, y1: number, y2: number, color: RGB, thickness = 0.6) =>
    page.drawLine({ start: { x, y: y1 }, end: { x, y: y2 }, thickness, color });
  // A "value in a labelled field": left/centre/right text within [x,w].
  const fieldText = (x: number, y: number, w: number, h: number, value: string, font: PDFFont, size: number, align: Align = "l", color: RGB = BLACK) => {
    if (!value) return;
    const tx = align === "l" ? x + 2 : align === "c" ? x + w / 2 : x + w - 3;
    text(tx, y + (h - size) / 2 + 1.5, value, font, size, color, align);
  };

  // page + accent bars
  fill(0, 0, W, H, PEARL);
  fill(0, H - 7, W, 7, PINK);
  fill(0, 0, W, 4, BLACK);

  // ---------- header ----------
  const top = H - 34;
  let logoDrew = false;
  if (d.logo) {
    try {
      const img = await pdf.embedPng(d.logo).catch(() => pdf.embedJpg(d.logo as Uint8Array));
      const LW = 132;
      const LH = (img.height / img.width) * LW;
      page.drawImage(img, { x: M - 4, y: top - LH, width: LW, height: LH });
      logoDrew = true;
    } catch { /* fall through to the name */ }
  }
  if (!logoDrew) {
    // No logo → the studio name in Bodoni, auto-fit so it never runs into the
    // "Service Invoice" title on the right.
    const maxW = W * 0.5 - M;
    let ns = 20;
    while (ns > 11 && BM.widthOfTextAtSize(d.seller.name, ns) > maxW) ns -= 0.5;
    text(M, top - 24, d.seller.name, BM, ns, BLACK, "l");
  }

  text(W - M, top - 22, "Service Invoice", BM, 27, BLACK, "r");
  label(W - M - 118, top - 44, "Invoice No.");
  fieldText(W - M - 118, top - 64, 118, 18, d.invoiceNo, MONOB, 15, "r", PINK);
  hline(W - M - 118, W - M, top - 66, PINK, 0.8);
  label(W - M - 118, top - 80, "Date");
  fieldText(W - M - 118, top - 98, 118, 16, d.date, SGM, 10, "r");
  hline(W - M - 118, W - M, top - 99, LINE);

  // ---------- seller ----------
  // Start below the whole header band (logo/name on the left, invoice-no/date
  // on the right, which ends ~top-99) so nothing overlaps.
  let y = top - 120;
  text(M, y, d.seller.name, SGB, 12.5, BLACK, "l");
  if (d.seller.proprietor) text(M, y - 14, d.seller.proprietor, SG, 8.5, PEWTER);
  if (d.seller.tin) text(M, y - 26, d.seller.tin, MONOB, 8.5, BLACK);
  const addr = d.seller.addressLines.slice(0, 3);
  addr.forEach((a, i) => text(M, y - 40 - i * 11, a, SG, 8.5, BLACK));

  const cx = W - M - 168;
  const contacts: [string, string | null | undefined][] = [
    ["Email", d.seller.email],
    ["Landline", d.seller.landline],
    ["Mobile", d.seller.mobile],
  ];
  contacts.forEach(([k, v], i) => {
    if (!v) return;
    const yy = y - 26 - i * 14;
    label(cx, yy, k);
    text(W - M, yy, v, SGM, 8.5, BLACK, "r");
  });
  const sellerBottom = y - 74;

  // ---------- sold to ----------
  y = sellerBottom - 14;
  fill(M, y - 1, 3, 9, PINK);
  label(M + 8, y, "Sold to", BLACK, "l", 7.5);
  const boxTop = y - 8;
  const bh = 104;
  fill(M, boxTop - bh, W - 2 * M, bh, WHITE);
  stroke(M, boxTop - bh, W - 2 * M, bh, LINE);
  const split = M + (W - 2 * M) * 0.64;
  vline(split, boxTop - 34, boxTop, LINE);
  hline(M, W - M, boxTop - 34, LINE);
  hline(M, W - M, boxTop - 68, LINE);
  vline(split, boxTop - bh, boxTop - 68, LINE);
  const pad = 10;
  label(M + pad, boxTop - 12, "Registered Name");
  fieldText(M + pad - 2, boxTop - 31, split - M - 2 * pad, 16, d.client.name, SGM, 9.5);
  label(split + pad, boxTop - 12, "TIN");
  label(M + pad, boxTop - 46, "Business Address");
  label(M + pad, boxTop - 80, "Email");
  fieldText(M + pad - 2, boxTop - 99, split - M - 2 * pad, 16, d.client.email ?? "", SGM, 9.5);
  label(split + pad, boxTop - 80, "Member / Booking Ref");
  fieldText(split + pad - 2, boxTop - 99, W - M - split - 2 * pad, 16, d.client.ref ?? "", MONO, 9);

  // ---------- items ----------
  y = boxTop - bh - 18;
  const tw = W - 2 * M;
  const cols = [M, M + tw * 0.56, M + tw * 0.68, M + tw * 0.84, W - M];
  const hh = 22;
  fill(M, y - hh, tw, hh, BLACK);
  label(cols[0] + 10, y - 14, "Item Description / Nature of Service", WHITE, "l", 7);
  label((cols[1] + cols[2]) / 2, y - 14, "Qty", WHITE, "c", 7);
  label(cols[3] - 8, y - 14, "Unit Price", WHITE, "r", 7);
  label(cols[4] - 10, y - 14, "Amount", WHITE, "r", 7);
  const rh = 24;
  const nrows = 5;
  fill(M, y - hh - rh * nrows, tw, rh * nrows, WHITE);
  for (let r = 0; r < nrows; r++) {
    const ry = y - hh - rh * (r + 1);
    if (r % 2 === 1) fill(M, ry, tw, rh, ROWALT);
    hline(M, W - M, ry, LINE);
    const it = d.items[r];
    if (it) {
      fieldText(cols[0] + 8, ry + 4, cols[1] - cols[0] - 12, 16, it.desc ?? "", SGM, 9);
      fieldText(cols[1] + 2, ry + 4, cols[2] - cols[1] - 4, 16, String(it.qty), MONO, 9, "c");
      fieldText(cols[2] + 2, ry + 4, cols[3] - cols[2] - 6, 16, pesoStr(it.price), MONO, 8.5, "r");
      fieldText(cols[3] + 2, ry + 4, cols[4] - cols[3] - 8, 16, pesoStr(it.qty * it.price), MONOB, 8.5, "r");
    }
  }
  cols.slice(1, 4).forEach((c) => vline(c, y - hh - rh * nrows, y - hh, LINE));
  stroke(M, y - hh - rh * nrows, tw, rh * nrows, LINE);
  text(M, y - hh - rh * nrows - 12, "All prices are VAT-inclusive (12%).", SG, 7, PEWTER);

  // ---------- bottom: left payment, right tax summary ----------
  const yb = y - hh - rh * nrows - 26;
  const rx = M + tw * 0.53;
  const rw = W - M - rx;
  const s = computeInvoice(d.items, { vatRate: d.seller.vatRate });
  const sumRows: [string, number][] = [
    ["Total Sales (VAT Inclusive)", s.totalSalesVatInclusive],
    ["Less: VAT", s.lessVat],
    ["Amount Net of VAT", s.amountNetOfVat],
    ["Less: SC/PWD Discount", s.lessScpwdDiscount],
    ["Total Due", s.totalDue],
    ["Less: Withholding Tax", s.lessWithholding],
    ["Amount Due", s.amountDue],
    ["Add: VAT", s.addVat],
  ];
  const srh = 16.5;
  fill(rx, yb - srh * sumRows.length - 6, rw, srh * sumRows.length + 6, WHITE);
  stroke(rx, yb - srh * sumRows.length - 6, rw, srh * sumRows.length + 6, LINE);
  sumRows.forEach(([k, v], i) => {
    const ry = yb - 3 - srh * (i + 1);
    if (i) hline(rx + 8, rx + rw - 8, ry + srh, LINE);
    text(rx + 10, ry + 5, k, SG, 8, BLACK);
    fieldText(rx + rw * 0.55, ry + 1, rw * 0.45 - 10, srh - 2, pesoStr(v), MONO, 8, "r");
  });
  // total band
  const ty = yb - srh * sumRows.length - 6 - 8 - 30;
  fill(rx, ty, rw, 30, PINK);
  label(rx + 10, ty + 11.5, "Total Amount Due", WHITE, "l", 7.5);
  fieldText(rx + rw * 0.45, ty + 5, rw * 0.55 - 10, 20, pesoStr(s.totalAmountDue), MONOB, 12, "r", WHITE);
  // VAT breakdown
  const vk: [string, number][] = [
    ["VATable Sales", s.vatableSales],
    ["VAT-Exempt Sales", s.vatExemptSales],
    ["VAT Zero-Rated Sales", s.vatZeroRatedSales],
    ["VAT Amount", s.vatAmount],
  ];
  const vy = ty - 8;
  vk.forEach(([k, v], i) => {
    const ry = vy - srh * (i + 1);
    text(rx + 10, ry + 5, k, SG, 7.8, PEWTER);
    fieldText(rx + rw * 0.55, ry + 1, rw * 0.45 - 10, srh - 2, pesoStr(v), MONO, 8, "r");
    hline(rx + 8, rx + rw - 8, ry, LINE, 0.6, [1, 2]);
  });
  const rightBottom = vy - srh * vk.length;

  // left column: payment
  const lx = M;
  const lw = rx - M - 18;
  label(lx, yb - 4, "Payment", BLACK, "l", 7.5);
  fill(lx - 8, yb - 5, 3, 9, PINK);
  const methods = ["Cash", "GCash", "Maya", "Card", "Bank Transfer"];
  let mx = lx;
  let my = yb - 26;
  for (const m of methods) {
    const bw = SGM.widthOfTextAtSize(m, 8) + 22;
    if (mx + bw > lx + lw) { mx = lx; my -= 20; }
    const on = m === d.method;
    page.drawRectangle({ x: mx, y: my - 4, width: bw, height: 15, color: on ? BLUSH : WHITE, borderColor: on ? PINK : LINE, borderWidth: 0.8 });
    // radio dot
    page.drawCircle({ x: mx + 8.5, y: my + 3.5, size: 3, color: on ? PINK : WHITE, borderColor: on ? PINK : PEWTER, borderWidth: 0.8 });
    text(mx + 15, my + 0.5, m, SGM, 8, BLACK);
    mx += bw + 6;
  }

  const lineField = (lbl: string, value: string, yy: number, font: PDFFont, size: number) => {
    label(lx, yy, lbl);
    fieldText(lx - 2, yy - 20, lw, 16, value, font, size);
    hline(lx, lx + lw, yy - 21, LINE, 0.7);
  };
  const fy = my - 26;
  lineField("Payment Reference No.", d.paymentRef ?? "", fy, MONO, 9);
  lineField("Amount Received", pesoStr(d.amountReceivedCents), fy - 36, MONOB, 9.5);
  // received by
  let yy = fy - 108;
  label(lx, yy, "Received by (Authorized Signature)");
  fieldText(lx - 2, yy - 22, lw, 18, d.receivedBy ?? "", BMI, 12);
  hline(lx, lx + lw, yy - 24, BLACK, 0.7);

  // PAID stamp
  if (d.paid) {
    const sx = lx + lw - 56;
    const sy = fy - 48;
    page.drawRectangle({ x: sx - 44, y: sy - 15, width: 88, height: 32, borderColor: PINK, borderWidth: 1.6, rotate: degrees(-12), color: undefined });
    text2(page, sx, sy - 5, "PAID", MONOB, 17, PINK, -12);
  }

  // ---------- footer ----------
  const fyb = Math.min(rightBottom, yy - 24) - 26;
  hline(M, W - M, fyb, BLACK, 0.8);
  text(M, fyb - 22, "Thank you for moving with us.", BMI, 14, BLACK);
  text(M, fyb - 35, "Keep this invoice for your records.", SG, 7.3, PEWTER);
  const comp: [string, string][] = [
    ["Acknowledgment Cert. / ATP No.", d.seller.atpNo || "—"],
    ["Date Issued", d.seller.atpDate || "—"],
    ["Approved Series", d.seller.series || "0000001 – 9999999"],
  ];
  comp.forEach(([k, v], i) => {
    label(W - M - 74, fyb - 18 - i * 11, k, PEWTER, "r", 5.8);
    text(W - M, fyb - 18 - i * 11, v, MONO, 6.8, BLACK, "r");
  });

  return pdf.save();

  // a centred rotated text, used only for the PAID stamp
  function text2(pg: PDFPage, x: number, yv: number, str: string, font: PDFFont, size: number, color: RGB, deg: number) {
    const w = font.widthOfTextAtSize(str, size);
    const rad = (deg * Math.PI) / 180;
    // offset so the text is roughly centred on (x,y) after rotation
    const dx = (-w / 2) * Math.cos(rad);
    const dy = (-w / 2) * Math.sin(rad);
    pg.drawText(str, { x: x + dx, y: yv + dy, size, font, color, rotate: degrees(deg) });
  }
}
