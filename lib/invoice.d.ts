export type InvoiceItem = { qty: number; price: number; desc?: string };

export type InvoiceSummary = {
  totalSalesVatInclusive: number;
  lessVat: number;
  amountNetOfVat: number;
  lessScpwdDiscount: number;
  totalDue: number;
  lessWithholding: number;
  amountDue: number;
  addVat: number;
  totalAmountDue: number;
  vatableSales: number;
  vatExemptSales: number;
  vatZeroRatedSales: number;
  vatAmount: number;
};

export function roundCents(x: number): number;
export function vatOf(grossCents: number, rate?: number): number;
export function computeInvoice(
  items: InvoiceItem[],
  opts?: { scpwdDiscount?: number; withholding?: number; vatRate?: number }
): InvoiceSummary;
export function invoiceMethod(provider: string | null, method: string | null): string;
export function pesoStr(cents: number): string;
export function hasInvoiceDetails(s: {
  invoice_registered_name?: string | null;
  invoice_tin?: string | null;
} | null | undefined): boolean;
