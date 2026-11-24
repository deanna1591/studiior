export function classLineText(input: { booked?: number; checkedIn?: number | null; headsPaid?: number | null; finalised?: boolean; fullHouse?: boolean; holdingFee?: boolean }): string;
export function lineStatusWords(status: string | null): string;
export function statusChip(status: string): { label: string; tone: "open" | "closed" | "paid" };
export function settleWording(input: { status?: string; settleOn?: string | null; paidOn?: string | null; method?: string | null }): string;
export function disputeMailto(input: { email?: string | null; periodLabel?: string; lineName?: string; lineWhen?: string; amount?: string }): string | null;
