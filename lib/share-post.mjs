// Decision 93 part (c) — Share a post. On a device that can share files, the
// system share sheet opens with the PNG and the caption (Web Share API with
// files). Where file sharing is not supported, the PNG downloads and the caption
// is copied, with a toast telling the person to paste it. pickShareMode is the
// pure decision (node-testable); sharePost is the DOM wrapper used by the pages.

/** The exact toast shown after the download-and-copy fallback. */
export const SHARE_FALLBACK_TOAST = "Image saved and caption copied. Paste it into your post.";

/** "share" when the platform can share this file via the Web Share API, else
 *  "fallback". A missing navigator, a missing share/canShare, or a throwing
 *  canShare all mean fallback. */
export function pickShareMode(nav, file) {
  if (!nav || typeof nav.share !== "function" || typeof nav.canShare !== "function") return "fallback";
  try {
    return file && nav.canShare({ files: [file] }) ? "share" : "fallback";
  } catch {
    return "fallback";
  }
}

/** Trigger a browser download of a blob (fallback path). */
function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/**
 * Share the post PNG + caption. Returns "shared" when it went to the share
 * sheet, "cancelled" when the person dismissed it, or "fallback" when the file
 * could not be shared (the PNG was downloaded and the caption copied).
 */
export async function sharePost({ blob, filename, caption }) {
  const file = new File([blob], filename, { type: "image/png" });
  const nav = typeof navigator !== "undefined" ? navigator : null;
  if (pickShareMode(nav, file) === "share") {
    try {
      await nav.share({ files: [file], text: caption });
      return "shared";
    } catch (e) {
      if (e && e.name === "AbortError") return "cancelled"; // the person dismissed it
      // any other failure falls through to the download-and-copy fallback
    }
  }
  downloadBlob(blob, filename);
  try { await navigator.clipboard.writeText(caption); } catch { /* best effort */ }
  return "fallback";
}
