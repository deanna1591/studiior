import { test } from "node:test";
import assert from "node:assert/strict";
import QRCode from "qrcode";
import { decodeQR } from "../lib/qr-decode.mjs";

// Rasterise a QR matrix to an RGBA buffer (SCALE px per module + a quiet zone),
// exactly as a camera frame would present it, and decode it back with jsQR —
// the same path the Scan component's fallback uses.
function render(code, scale = 8, quiet = 4) {
  const qr = QRCode.create(code, { errorCorrectionLevel: "M" });
  const n = qr.modules.size;
  const bits = qr.modules.data;
  const dim = (n + quiet * 2) * scale;
  const data = new Uint8ClampedArray(dim * dim * 4).fill(255); // white
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (!bits[y * n + x]) continue; // light module stays white
      for (let dy = 0; dy < scale; dy++) {
        for (let dx = 0; dx < scale; dx++) {
          const px = ((quiet + x) * scale + dx) + ((quiet + y) * scale + dy) * dim;
          data[px * 4] = 0; data[px * 4 + 1] = 0; data[px * 4 + 2] = 0;
        }
      }
    }
  }
  return { data, dim };
}

test("jsQR decodes a generated QR of an 8-char code", () => {
  const code = "7F3A9C2E";
  const { data, dim } = render(code);
  assert.equal(decodeQR(data, dim, dim), code);
});

test("decodeQR returns null for an all-white frame", () => {
  const dim = 64;
  const data = new Uint8ClampedArray(dim * dim * 4).fill(255);
  assert.equal(decodeQR(data, dim, dim), null);
});
