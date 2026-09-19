"use server";

import { headers } from "next/headers";
import { revalidatePath } from "next/cache";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { getMemberContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type SignResult = { ok: true } | { ok: false; message: string } | null;

// Decision 34: the member signs the current waiver version. This runs with the
// MEMBER's own session (no service-role client): it builds the signed PDF, writes
// it and the signature PNG to the member's own member-documents folder (the
// member-self storage policy), then records it through sign_waiver_document,
// which sets waiver_signed_at exactly as the paper path does.
//
// The name in the document is the member ROW's, not client input — the DB
// re-derives and stores it too, so a tampered client cannot change who signed.
export async function signWaiver(
  _prev: SignResult, formData: FormData,
): Promise<SignResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const supabase = createClient();

  const versionId = String(formData.get("version_id") ?? "");
  const sigDataUrl = String(formData.get("signature") ?? "");
  if (!versionId) return { ok: false, message: "Reload the waiver and try again." };
  if (!sigDataUrl.startsWith("data:image/png;base64,")) {
    return { ok: false, message: "Please draw your signature before signing." };
  }

  // The current version, read as the member — the source of truth for the hash
  // and the content that goes into the PDF.
  const { data: cur, error: curErr } = await supabase.rpc("current_waiver", {
    p_studio_id: ctx.studioId,
  });
  if (curErr) return { ok: false, message: curErr.message };
  const w = cur as {
    exists?: boolean; version_id?: string; format?: string; body?: string | null;
    storage_path?: string | null; content_hash?: string;
  } | null;
  if (!w?.exists) return { ok: false, message: "This studio has not provided a waiver yet." };
  if (w.version_id !== versionId) {
    return { ok: false, message: "The waiver has changed — reload and sign the current version." };
  }

  const name = ctx.name?.trim() || "Member";
  const signedAt = new Date();
  const whenLocal = new Intl.DateTimeFormat("en-GB", {
    weekday: "long", day: "numeric", month: "long", year: "numeric",
    hour: "2-digit", minute: "2-digit", timeZone: ctx.timeZone,
  }).format(signedAt);
  const sigBytes = Buffer.from(sigDataUrl.split(",")[1], "base64");

  // Build the signed PDF: the waiver content, then a signature block appended at
  // the end (there is no field-placement editor — always the end).
  let pdf: PDFDocument;
  try {
    if (w.format === "pdf" && w.storage_path) {
      // The studio's uploaded PDF lives in the public studio-branding bucket.
      const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(w.storage_path);
      const res = await fetch(pub.publicUrl);
      pdf = await PDFDocument.load(await res.arrayBuffer());
    } else {
      pdf = await PDFDocument.create();
      const font = await pdf.embedFont(StandardFonts.Helvetica);
      const A4 = { w: 595.28, h: 841.89 };
      const margin = 54, size = 11, lh = 15;
      let page = pdf.addPage([A4.w, A4.h]);
      let y = A4.h - margin;
      const maxW = A4.w - margin * 2;
      const wrap = (text: string): string[] => {
        const out: string[] = [];
        for (const para of text.split("\n")) {
          let line = "";
          for (const word of para.split(/\s+/)) {
            const t = line ? line + " " + word : word;
            if (font.widthOfTextAtSize(t, size) > maxW && line) { out.push(line); line = word; }
            else line = t;
          }
          out.push(line);
        }
        return out;
      };
      for (const line of wrap(w.body ?? "")) {
        if (y < margin + lh) { page = pdf.addPage([A4.w, A4.h]); y = A4.h - margin; }
        page.drawText(line, { x: margin, y, size, font, color: rgb(0.1, 0.1, 0.1) });
        y -= lh;
      }
    }

    // The signature block, on a fresh page at the end.
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const page = pdf.addPage();
    const { width, height } = page.getSize();
    const m = 54;
    let y = height - m;
    page.drawText("Signature", { x: m, y, size: 16, font: bold, color: rgb(0.1, 0.1, 0.1) });
    y -= 30;
    const png = await pdf.embedPng(sigBytes);
    const dims = png.scale(Math.min(1, 260 / png.width));
    page.drawImage(png, { x: m, y: y - dims.height, width: dims.width, height: dims.height });
    // A ruled line under the signature.
    page.drawLine({ start: { x: m, y: y - dims.height - 4 }, end: { x: m + 300, y: y - dims.height - 4 },
                    thickness: 0.5, color: rgb(0.6, 0.6, 0.6) });
    y = y - dims.height - 24;
    const rows = [
      ["Signed by", name],
      ["Date", whenLocal],
      ["Waiver version", versionId],
      ["Content hash", w.content_hash ?? ""],
    ];
    for (const [k, v] of rows) {
      page.drawText(k, { x: m, y, size: 9, font: bold, color: rgb(0.4, 0.4, 0.4) });
      page.drawText(v, { x: m + 90, y, size: 9, font, color: rgb(0.2, 0.2, 0.2) });
      y -= 16;
    }
    var pdfBytes = await pdf.save();
  } catch {
    return { ok: false, message: "The signed document could not be produced. Please try again." };
  }

  // Write both to the member's own folder (<studio>/<member>/…).
  const ts = Date.now();
  const base = `${ctx.studioId}/${ctx.memberId}`;
  const docPath = `${base}/waiver-${ts}.pdf`;
  const sigPath = `${base}/waiver-signature-${ts}.png`;

  const up1 = await supabase.storage.from("member-documents")
    .upload(sigPath, sigBytes, { contentType: "image/png", upsert: false });
  if (up1.error) {
    return /row-level security|Unauthorized/i.test(up1.error.message)
      ? { ok: false, message: "Your signature could not be saved to your account." }
      : { ok: false, message: up1.error.message };
  }
  const up2 = await supabase.storage.from("member-documents")
    .upload(docPath, pdfBytes, { contentType: "application/pdf", upsert: false });
  if (up2.error) return { ok: false, message: up2.error.message };

  const h = headers();
  const ip = (h.get("x-forwarded-for")?.split(",")[0] ?? h.get("x-real-ip") ?? "").trim();
  const { data, error } = await supabase.rpc("sign_waiver_document", {
    p_member_id: ctx.memberId,
    p_version_id: versionId,
    p_content_hash: w.content_hash!,
    p_document_path: docPath,
    p_document_filename: `waiver-${ts}.pdf`,
    p_document_size: pdfBytes.length,
    p_signature_path: sigPath,
    p_user_agent: h.get("user-agent") ?? undefined,
    p_ip: ip || undefined,
  });
  if (error) return { ok: false, message: error.message };
  const r = data as { ok?: boolean } | null;
  if (!r?.ok) return { ok: false, message: "That didn't work — please try again." };

  for (const p of ["/", "/book", "/account", "/waiver"]) revalidatePath(p);
  return { ok: true };
}
