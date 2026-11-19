export function giftAmountProblem(cents: number, minCents?: number): string | null;
export function isGiftCode(code: string | null | undefined): boolean;
export function contrastRatio(a: string, b: string): number;
export function cardLayout(a: { accent: string | null | undefined; hasImage: boolean }): {
  width: number; height: number; background: string | null; band: string | null;
  ink: string; inkContrast: number;
};
