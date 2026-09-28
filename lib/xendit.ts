/**
 * Xendit Payment Sessions client (Decision 40, Part A).
 *
 * Verified against docs.xendit.co and a live test-mode call:
 *  - POST /sessions        create a PAY session (mode PAYMENT_LINK)
 *  - GET  /sessions/{id}    read a session's status (reconciliation)
 *  - GET  /balance          harmless key check ("Test connection")
 * Auth is HTTP Basic with the tenant's secret key as the USERNAME (empty password).
 *
 * AMOUNT IS IN MAJOR UNITS (whole pesos), NOT centavos — proven live: amount 1500
 * renders as ₱1,500 on the hosted checkout. Our DB stores cents, so the single
 * unit assumption lives in the two helpers below and nowhere else.
 *
 * Server-only. The secret key is passed in decrypted by the caller; this module
 * never reads it from env and never logs it.
 */

const BASE = "https://api.xendit.co";

export function pesosFromCents(cents: number): number {
  return Math.round(cents) / 100;
}
export function centsFromXenditAmount(amount: number): number {
  return Math.round(amount * 100);
}

function authHeader(secretKey: string): string {
  return "Basic " + Buffer.from(`${secretKey}:`).toString("base64");
}

export type CreateSessionInput = {
  referenceId: string; // OUR purchase id
  amountCents: number;
  currency: string; // e.g. "PHP"
  country?: string; // e.g. "PH" — required by Xendit
  description?: string;
  customerEmail?: string;
  customerName?: string;
  metadata?: Record<string, string>;
  successUrl: string;
  cancelUrl: string;
};

export type CreateSessionResult = {
  payment_session_id: string;
  payment_link_url: string;
  status: string;
};

export type XenditError = { status: number; code?: string; message: string };

async function call<T>(
  secretKey: string,
  path: string,
  init: RequestInit,
): Promise<{ ok: true; data: T } | { ok: false; error: XenditError }> {
  let res: Response;
  try {
    res = await fetch(`${BASE}${path}`, {
      ...init,
      headers: {
        Authorization: authHeader(secretKey),
        "Content-Type": "application/json",
        ...(init.headers ?? {}),
      },
      cache: "no-store",
    });
  } catch (e) {
    return { ok: false, error: { status: 0, message: e instanceof Error ? e.message : "network error" } };
  }
  const text = await res.text();
  let body: unknown = null;
  try { body = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
  if (!res.ok) {
    const b = body as { error_code?: string; message?: string } | null;
    return { ok: false, error: { status: res.status, code: b?.error_code, message: b?.message ?? text.slice(0, 300) } };
  }
  return { ok: true, data: body as T };
}

export function createSession(secretKey: string, input: CreateSessionInput) {
  const body: Record<string, unknown> = {
    reference_id: input.referenceId,
    session_type: "PAY",
    mode: "PAYMENT_LINK",
    amount: pesosFromCents(input.amountCents),
    currency: input.currency,
    country: input.country ?? "PH",
    success_return_url: input.successUrl,
    cancel_return_url: input.cancelUrl,
  };
  if (input.description) body.description = input.description;
  if (input.metadata) body.metadata = input.metadata;
  if (input.customerEmail || input.customerName) {
    body.customer = {
      type: "INDIVIDUAL",
      ...(input.customerEmail ? { email: input.customerEmail } : {}),
      ...(input.customerName ? { individual_detail: { given_names: input.customerName } } : {}),
    };
  }
  return call<CreateSessionResult>(secretKey, "/sessions", { method: "POST", body: JSON.stringify(body) });
}

export type SessionStatus = {
  payment_session_id: string;
  status: string; // ACTIVE | COMPLETED | EXPIRED | CANCELED
  payment_id?: string | null;
  reference_id?: string;
  amount?: number;
  currency?: string;
};

export function getSession(secretKey: string, sessionId: string) {
  return call<SessionStatus>(secretKey, `/sessions/${encodeURIComponent(sessionId)}`, { method: "GET" });
}

export function getBalance(secretKey: string) {
  return call<{ balance: number }>(secretKey, "/balance", { method: "GET" });
}
