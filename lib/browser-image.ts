"use client";

// Decision 93 amendment — the ONE browser downscale the upload inputs call
// (brand-kit references, schedule-post edit photos). It delegates to
// lib/image-shrink.mjs (the canvas work, node-tested via fitBox); this file only
// adds the reference/edit presets and passes PDFs through untouched. No second
// canvas implementation.
import { shrinkImage } from "@/lib/image-shrink";

export const REFERENCE_MAX_PX = 2000; // brand references
export const EDIT_PHOTO_MAX_PX = 1600; // post-edit photos

/**
 * Shrink an image to `maxPx` on its long side (JPEG q0.85, PNG kept when it has
 * transparency). A PDF is returned untouched — references accept PDF and PDFs are
 * not shrunk. On any decode failure the original is returned (never a dropped
 * upload). Browser-only (createImageBitmap/canvas).
 */
export async function prepareUpload(file: File, maxPx: number): Promise<File> {
  if (file.type === "application/pdf") return file;
  return shrinkImage(file, { maxPx, mode: "fit", keepAlpha: true });
}

/** The stored extension for a prepared file — shrinkImage emits jpg or png. */
export function uploadExt(file: File): string {
  if (file.type === "application/pdf") return "pdf";
  if (file.type === "image/png") return "png";
  if (file.type === "image/webp") return "webp";
  return "jpg";
}
