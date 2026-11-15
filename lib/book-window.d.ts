export const LOAD_CAP: number;
export function loadLen(monthView: boolean, gridLength: number, stripLen?: number): number;
export function windowOffsets(gridFromOffset: number, len: number): number[];
export function covers(offsets: number[], from: number, to: number): boolean;
