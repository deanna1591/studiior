import { createCipheriv, createDecipheriv, randomBytes, createHash } from "node:crypto";

/**
 * AES-256-GCM at-rest encryption for per-tenant integration secrets
 * (Decision 40 — Xendit's secret key and callback token).
 *
 * The key is INTEGRATIONS_ENCRYPTION_KEY, 32 bytes base64, held ONLY in the
 * server runtime env (Vercel) — never in the database, the repo or logs. The
 * database stores only the ciphertext this produces; a full table read yields
 * nothing usable without this key.
 *
 * Stored form: "v1." + base64( iv(12) ‖ authTag(16) ‖ ciphertext ).
 * Server-only: this imports node:crypto and must never reach a client bundle.
 */

const VERSION = "v1";
const IV_LEN = 12;
const TAG_LEN = 16;

function key(): Buffer {
  const raw = process.env.INTEGRATIONS_ENCRYPTION_KEY;
  if (!raw) throw new Error("INTEGRATIONS_ENCRYPTION_KEY is not set on this server.");
  const buf = Buffer.from(raw.trim(), "base64");
  if (buf.length !== 32) {
    throw new Error("INTEGRATIONS_ENCRYPTION_KEY must be 32 bytes, base64-encoded.");
  }
  return buf;
}

export function encryptSecret(plaintext: string): string {
  const iv = randomBytes(IV_LEN);
  const cipher = createCipheriv("aes-256-gcm", key(), iv);
  const ct = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${VERSION}.${Buffer.concat([iv, tag, ct]).toString("base64")}`;
}

export function decryptSecret(stored: string): string {
  const [v, b64] = stored.split(".", 2);
  if (v !== VERSION || !b64) throw new Error("unrecognised ciphertext format");
  const buf = Buffer.from(b64, "base64");
  const iv = buf.subarray(0, IV_LEN);
  const tag = buf.subarray(IV_LEN, IV_LEN + TAG_LEN);
  const ct = buf.subarray(IV_LEN + TAG_LEN);
  const decipher = createDecipheriv("aes-256-gcm", key(), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]).toString("utf8");
}

/** The sha256 hex the anon webhook verifies the x-callback-token against in SQL. */
export function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}
