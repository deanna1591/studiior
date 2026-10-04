export function squareCrop(
  w: number,
  h: number,
  max: number,
): { sx: number; sy: number; side: number; target: number };

export function shrinkToSquare(file: File, max?: number): Promise<File>;
