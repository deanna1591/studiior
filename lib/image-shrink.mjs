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
