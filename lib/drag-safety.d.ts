export function resolveDrag(
  origStartMs: number,
  dropStartMs: number,
  opts: { columnChanged: boolean; isDay: boolean; stepMin: number },
): { startMs: number; snapped: boolean; timeChanged: boolean };
