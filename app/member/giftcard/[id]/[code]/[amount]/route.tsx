import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { anonStudio } from "@/lib/anon-studio";
import { neutralAccent, type PresetKey } from "@/lib/theme";
import { formatMoney } from "@/lib/plans";
import {
  cardAmountLabel, cardLayout, giftAmountProblem, isGiftCode,
  GIFT_CARD_FONT_FAMILY, GIFT_CARD_FONTS,
} from "@/lib/gift-card";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 110 amendment (a) — the composited gift card: the amount and the code
 * drawn onto the studio's uploaded card (Settings → Gift cards), or onto a
 * default card in the studio accent when none is uploaded. Rendered with
 * next/og (no sharp), the member icon route's pattern.
 *
 * The path is stored on gift_cards.card_image_path at issue and carried on
 * gift_card_sent as {card_image_url}: /giftcard/{card id}/{code}/{amount}. The
 * route reads nothing per card (there is no anon reader for a card, and the
 * anon surface stays fourteen): the amount and code arrive in the path. It
 * refuses a code that is not this studio's shape and an amount outside the gift
 * rule, so it only ever draws a card the studio could have issued. An image
 * confers nothing — redemption checks the code against the database.
 * Extension-less because the middleware matcher excludes .png. Immutable: the
 * path IS the card.
 */
// The card font (it carries ₱; next/og's built-in one does not). The bundled
// copy first (outputFileTracingIncludes), else the public file — the receipt
// route's pattern. Null when neither loads; the card then writes the ISO code.
async function loadCardFonts(reqUrl: string) {
  const dir = join(process.cwd(), "public", "fonts", "invoice");
  const out: { name: string; data: ArrayBuffer; weight: 400 | 500 | 700; style: "normal" }[] = [];
  for (const f of GIFT_CARD_FONTS) {
    let data: ArrayBuffer | null = null;
    try {
      const b = await readFile(join(dir, f.file));
      data = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;
    } catch { /* not bundled */ }
    if (!data) {
      try {
        const ctl = new AbortController();
        const t = setTimeout(() => ctl.abort(), 6000);
        const res = await fetch(new URL(`/fonts/invoice/${f.file}`, reqUrl), { signal: ctl.signal });
        clearTimeout(t);
        if (res.ok) data = await res.arrayBuffer();
      } catch { /* unreachable */ }
    }
    if (!data) return null;
    out.push({ name: GIFT_CARD_FONT_FAMILY, data, weight: f.weight, style: "normal" });
  }
  return out;
}

export async function GET(
  req: Request,
  { params }: { params: { id: string; code: string; amount: string } },
) {
  const studio = await anonStudio();
  if (!studio) return new Response("Not found", { status: 404 });

  const code = decodeURIComponent(params.code).toUpperCase();
  const amount = Number(params.amount);
  const prefix = (studio.slug ?? "").replace(/[^a-zA-Z0-9]/g, "").slice(0, 4).toUpperCase() || "GIFT";
  if (!/^[0-9a-f-]{36}$/i.test(params.id) || !isGiftCode(code) || !code.startsWith(prefix + "-")
      || !Number.isInteger(amount) || giftAmountProblem(amount, studio.gift_min_cents ?? 50000)) {
    return new Response("Not found", { status: 404 });
  }

  const preset = (studio.theme_preset ?? "warm") as PresetKey;
  const accent = studio.accent_color ?? neutralAccent(preset);
  const image = studio.gift_card_image_url ?? null;
  const L = cardLayout({ accent, hasImage: !!image });
  const currency = studio.currency ?? "PHP";
  const fonts = await loadCardFonts(req.url);
  const amountLabel = cardAmountLabel(formatMoney(amount, currency), currency, !!fonts);

  return new ImageResponse(
    (
      <div style={{
        width: L.width, height: L.height, display: "flex", position: "relative",
        background: L.background ?? "#14170E", overflow: "hidden",
        fontFamily: fonts ? `"${GIFT_CARD_FONT_FAMILY}"` : "sans-serif",
      }}>
        {image ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={image} width={L.width} height={L.height}
               style={{ position: "absolute", inset: 0, width: L.width, height: L.height, objectFit: "cover" }} />
        ) : null}
        <div style={{
          position: "absolute", left: 0, right: 0, bottom: 0, display: "flex",
          flexDirection: "column", padding: "44px 64px",
          background: L.band ?? "transparent", color: L.ink,
        }}>
          <div style={{ fontSize: 34, fontWeight: 600, opacity: 1 }}>{studio.name}</div>
          <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", marginTop: 8 }}>
            <div style={{ fontSize: 112, fontWeight: 800, lineHeight: 1 }}>{amountLabel}</div>
            <div style={{ fontSize: 44, fontWeight: 700, letterSpacing: 4 }}>{code}</div>
          </div>
        </div>
        {!image ? (
          <div style={{
            position: "absolute", top: 56, left: 64, fontSize: 40, fontWeight: 700,
            color: L.ink, display: "flex",
          }}>
            Gift card
          </div>
        ) : null}
      </div>
    ),
    {
      width: L.width, height: L.height,
      ...(fonts ? { fonts } : {}),
      headers: { "Cache-Control": "public, max-age=31536000, immutable" },
    },
  );
}
