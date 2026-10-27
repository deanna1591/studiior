// Decision 60 — shrink an uploaded photo to a centred square in the browser,
// so a phone photo (several MB, any aspect) becomes a small square JPEG before
// it leaves the device. The 5 MB limit is checked on the ORIGINAL; the stored
// file is typically well under 200 KB.
//
// squareCrop is the pure box maths and is node-tested. shrinkToSquare does the
// canvas work and runs only in the browser — it is defined here (not called at
// import), so node can import this module to exercise squareCrop.

/**
 * The centred square crop of a w×h image, scaled to at most `max` px.
 * Returns the source crop rect (sx, sy, side) and the output size (target).
 * A landscape image keeps its full height and loses the sides; a portrait the
 * reverse; a square is untouched but still capped at `max`.
 */
export function squareCrop(w, h, max) {
  const side = Math.min(w, h);
  const sx = Math.round((w - side) / 2);
  const sy = Math.round((h - side) / 2);
  const target = Math.min(side, max);
  return { sx, sy, side, target };
}

/**
 * Read `file`, crop to a centred square of at most `max` px, re-encode as JPEG
 * at 0.85. Always JPEG (not PNG/WebP): an instructor photo is a face, not a
 * logo, so there is no transparency to keep and JPEG is the smallest. Returns a
 * new File named photo.jpg. Throws if the image cannot be decoded.
 */
export async function shrinkToSquare(file, max = 800) {
  const bmp = await createImageBitmap(file);
  try {
    const { sx, sy, side, target } = squareCrop(bmp.width, bmp.height, max);
    const canvas = document.createElement("canvas");
    canvas.width = target;
    canvas.height = target;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("no 2d context");
    ctx.drawImage(bmp, sx, sy, side, side, 0, 0, target, target);
    const blob = await new Promise((resolve, reject) =>
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("toBlob failed"))), "image/jpeg", 0.85),
    );
    return new File([blob], "photo.jpg", { type: "image/jpeg" });
  } finally {
    bmp.close?.();
  }
}

// --- Egress note (CLAUDE.md) --------------------------------------------------
// studio-branding photos (logo, login, class-type, covers, email image) and
// member avatars used to upload the RAW file — 0.4–1.8 MB PNGs served full-size
// on every member page, in every email frame and in the public embed, with only
// a 1-hour cache. shrinkToFit (aspect-preserving, NOT the square crop) lets a
// wide login photo / class card / cover shrink to its longer side without being
// cropped to a square, which squareCrop would do. Caps per surface are the
// caller's: logo ≤512, login/covers ≤1280, class-type ≤800, avatars ≤512 (square).

/**
 * The target box for a w×h image fit within `max` on its longer side, aspect
 * preserved, NEVER upscaled. Pure box maths, node-tested.
 */
export function fitBox(w, h, max) {
  const scale = Math.min(1, max / Math.max(w, h));
  return { tw: Math.max(1, Math.round(w * scale)), th: Math.max(1, Math.round(h * scale)) };
}

/**
 * Read `file`, scale (not crop) so its longer side is at most `max` px, aspect
 * preserved. `quality` is the JPEG quality; pass null to keep PNG (for a logo
 * with transparency). Returns a new File. Browser-only (canvas). Throws if the
 * image cannot be decoded.
 */
export async function shrinkToFit(file, max = 1280, quality = 0.85) {
  const bmp = await createImageBitmap(file);
  try {
    const { tw, th } = fitBox(bmp.width, bmp.height, max);
    const canvas = document.createElement("canvas");
    canvas.width = tw;
    canvas.height = th;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("no 2d context");
    ctx.drawImage(bmp, 0, 0, bmp.width, bmp.height, 0, 0, tw, th);
    const png = quality == null;
    const blob = await new Promise((resolve, reject) =>
      canvas.toBlob(
        (b) => (b ? resolve(b) : reject(new Error("toBlob failed"))),
        png ? "image/png" : "image/jpeg",
        png ? undefined : quality,
      ),
    );
    return new File([blob], png ? "image.png" : "image.jpg", { type: png ? "image/png" : "image/jpeg" });
  } finally {
    bmp.close?.();
  }
}

/**
 * Does this image carry any transparency? Only a PNG/WebP can — a JPEG never
 * does — so the caller tests type first. Samples a small downscale and scans the
 * alpha channel. Browser-only; any failure answers false (treat as opaque).
 */
export async function hasAlpha(file) {
  if (file.type !== "image/png" && file.type !== "image/webp") return false;
  let bmp;
  try {
    bmp = await createImageBitmap(file);
    const { tw, th } = fitBox(bmp.width, bmp.height, 64);
    const canvas = document.createElement("canvas");
    canvas.width = tw;
    canvas.height = th;
    const ctx = canvas.getContext("2d");
    if (!ctx) return false;
    ctx.drawImage(bmp, 0, 0, tw, th);
    const { data } = ctx.getImageData(0, 0, tw, th);
    for (let i = 3; i < data.length; i += 4) if (data[i] < 255) return true;
    return false;
  } catch {
    return false;
  } finally {
    bmp?.close?.();
  }
}

/**
 * The one entry point the upload inputs call. `mode` 'square' centre-crops (for
 * a face in a circular frame); 'fit' preserves aspect. `keepAlpha` (the logo
 * only) keeps PNG when the source is actually transparent, else flattens to
 * JPEG. An SVG is returned untouched — it is a vector, tiny, and rasterizing it
 * would make it worse. On any decode failure the ORIGINAL file is returned, so
 * the upload still goes through (larger, but never a dropped upload).
 */
export async function shrinkImage(file, { maxPx = 1280, mode = "fit", keepAlpha = false } = {}) {
  if (file.type === "image/svg+xml") return file;
  try {
    if (mode === "square") return await shrinkToSquare(file, maxPx);
    const useAlpha = keepAlpha && (await hasAlpha(file));
    return await shrinkToFit(file, maxPx, useAlpha ? null : 0.85);
  } catch {
    return file;
  }
}
