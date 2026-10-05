// The camera-scan decode, shared by the instructor Scan component (the jsQR
// fallback where BarcodeDetector is absent) and its node test. jsQR is a
// bundled dependency — no CDN. Takes an RGBA buffer and its dimensions;
// returns the decoded string or null.
import jsQR from "jsqr";
export function decodeQR(data, width, height) {
  const result = jsQR(data, width, height);
  return result ? result.data : null;
}
