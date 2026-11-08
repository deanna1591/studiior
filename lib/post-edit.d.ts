import type { BrandSpec } from "./brand-kit";

export function editResult(
  spec: BrandSpec | null,
  opts?: { photoPath?: string | null; current?: BrandSpec | null },
): { ok: true; spec: BrandSpec; note?: string } | { ok: false };
