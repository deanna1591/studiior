// Types for lib/brand-kit.mjs (Decision 93 slice 1). See the .mjs for the shape.
export interface BrandSpec {
  colors: { background: string; surface: string; ink: string; accent: string; secondary: string };
  display_font: string;
  body_font: string;
  layout: "list" | "grid" | "poster";
  radius: "small" | "large";
  tone: string;
  logo_placement: "top-left" | "top-centre" | "bottom";
  background_treatment: "none" | "soft" | "full";
  // optional per-post layout fields (slice 3)
  background_image?: string;
  image_placement?: "top" | "left" | "right" | "full";
  overlay_strength?: number;
  text_align?: "left" | "center" | "right";
  size_scale?: { time?: number; name?: number; header?: number };
  element_order?: Array<"logo" | "title" | "classes" | "footer">;
}
export const BRAND_FONTS: string[];
export const LAYOUTS: Array<"list" | "grid" | "poster">;
export const RADII: Array<"small" | "large">;
export const LOGO_PLACEMENTS: Array<"top-left" | "top-centre" | "bottom">;
export const BACKGROUND_TREATMENTS: Array<"none" | "soft" | "full">;
export const IMAGE_PLACEMENTS: Array<"top" | "left" | "right" | "full">;
export const TEXT_ALIGNS: Array<"left" | "center" | "right">;
export const ORDER_TOKENS: Array<"logo" | "title" | "classes" | "footer">;
export function isValidSpec(spec: unknown): boolean;
export function parseBrandSpec(text: string | null | undefined): BrandSpec | null;
export function defaultSpec(opts?: { accent?: string; themePreset?: string }): BrandSpec;
