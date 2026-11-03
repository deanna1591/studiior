export type WalletPayment = {
  id: string;
  amount_cents: number;
  currency: string;
  status: string;
  refunded_cents: number;
  refunded_at: string | null;
  provider: string | null;
  method: string | null;
  card_brand: string | null;
  card_last4: string | null;
  at: string;
  item: string;
};

export type WalletOnline = {
  id: string;
  amount_cents: number;
  currency: string;
  status: string;
  at: string;
  item: string;
};

export type WalletDesk = {
  booking_id: string;
  occurrence_id: string;
  item: string;
  starts_at: string;
  due_cents: number | null;
  currency: string;
};

export type Wallet = { payments: WalletPayment[]; online: WalletOnline[]; desk: WalletDesk[] };

export function walletBuckets(wallet: Partial<Wallet>): {
  unpaid: WalletOnline[];
  paid: WalletPayment[];
  refunded: WalletPayment[];
  desk: WalletDesk[];
};

export function usedOfTotal(m: { plan_credits?: number | null; credits_remaining?: number | null }): string | null;
export function membershipTab(planType: string): "subscriptions" | "passes";
export function membershipChip(status: string): "Active" | "Expired";
export function receiptMethod(provider: string | null, method: string | null): string;
export function onlineStatusLabel(status: string): string;
