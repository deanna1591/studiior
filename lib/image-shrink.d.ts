export function squareCrop(
  w: number,
  h: number,
  max: number,
): { sx: number; sy: number; side: number; target: number };

export function shrinkToSquare(file: File, max?: number): Promise<File>;

export function fitBox(w: number, h: number, max: number): { tw: number; th: number };

export function shrinkToFit(file: File, max?: number, quality?: number | null): Promise<File>;

export function hasAlpha(file: File): Promise<boolean>;

export function shrinkImage(
  file: File,
  opts?: { maxPx?: number; mode?: "fit" | "square"; keepAlpha?: boolean },
): Promise<File>;
