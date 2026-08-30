/**
 * Just enough CSV, and just enough date guessing, for a real studio export.
 *
 * Mindbody and Glofox files are not the tidy CSVs a parser demo uses: quoted
 * fields with commas inside, a name in one column or two, blank cells, and
 * dates in whichever format the exporting machine's locale produced.
 */

/** RFC 4180-ish: quoted fields, doubled quotes, CRLF or LF. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;

  const src = text.replace(/^﻿/, ""); // Excel writes a BOM
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (quoted) {
      if (c === '"') {
        if (src[i + 1] === '"') { field += '"'; i++; } else { quoted = false; }
      } else field += c;
      continue;
    }
    if (c === '"') { quoted = true; continue; }
    if (c === ",") { row.push(field); field = ""; continue; }
    if (c === "\r") continue;
    if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; continue; }
    field += c;
  }
  if (field !== "" || row.length > 0) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((c) => c.trim() !== ""));
}

export type DateOrder = "iso" | "dmy" | "mdy" | "unknown";

/**
 * Work out a column's date format from the whole column, not row by row.
 *
 * 03/04/2024 is ambiguous alone. If any value in the same column has a first
 * part above 12 it must be a day, which settles the rest — and getting this
 * wrong silently shifts a member's history by months rather than failing.
 */
export function detectDateOrder(values: string[]): DateOrder {
  let sawIso = false, firstOver12 = false, secondOver12 = false, sawSlash = false;
  for (const raw of values) {
    const v = raw.trim();
    if (!v) continue;
    if (/^\d{4}-\d{1,2}-\d{1,2}/.test(v)) { sawIso = true; continue; }
    const m = v.match(/^(\d{1,2})[\/.](\d{1,2})[\/.](\d{2,4})/);
    if (!m) continue;
    sawSlash = true;
    if (Number(m[1]) > 12) firstOver12 = true;
    if (Number(m[2]) > 12) secondOver12 = true;
  }
  if (firstOver12) return "dmy";
  if (secondOver12) return "mdy";
  if (sawIso && !sawSlash) return "iso";
  return sawSlash ? "unknown" : "iso";
}

/** Returns an ISO date, or null when the value cannot be read as one. */
export function normalizeDate(raw: string, order: DateOrder): string | null {
  const v = (raw ?? "").trim();
  if (!v) return null;

  const iso = v.match(/^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
  if (iso) {
    const [, y, mo, d, h = "0", mi = "0", s = "0"] = iso;
    return new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi, +s)).toISOString();
  }

  const parts = v.match(/^(\d{1,2})[\/.](\d{1,2})[\/.](\d{2,4})(?:[T ,]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?)?/);
  if (!parts) return null;
  const [, a, b, yRaw, hRaw = "0", mi = "0", s = "0", ampm] = parts;
  const year = yRaw.length === 2 ? 2000 + Number(yRaw) : Number(yRaw);
  // "unknown" means the column never disambiguated itself; day-first is the
  // safer default outside the US and the mapping screen says which was used.
  const dayFirst = order !== "mdy";
  const day = dayFirst ? Number(a) : Number(b);
  const month = dayFirst ? Number(b) : Number(a);
  let hour = Number(hRaw);
  if (ampm) {
    const pm = /p/i.test(ampm);
    if (pm && hour < 12) hour += 12;
    if (!pm && hour === 12) hour = 0;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return new Date(Date.UTC(year, month - 1, day, hour, Number(mi), Number(s))).toISOString();
}

/** "Ana Novak" -> ["Ana", "Novak"]; "Novak, Ana" -> ["Ana", "Novak"]. */
export function splitName(full: string): [string, string] {
  const v = (full ?? "").trim().replace(/\s+/g, " ");
  if (!v) return ["", ""];
  if (v.includes(",")) {
    const [last, first] = v.split(",", 2).map((p) => p.trim());
    return [first ?? "", last ?? ""];
  }
  const bits = v.split(" ");
  if (bits.length === 1) return [bits[0], ""];
  return [bits.slice(0, -1).join(" "), bits[bits.length - 1]];
}

/** Fields each import type understands, and what a header might call them. */
export const FIELDS: Record<string, { key: string; label: string; hints: string[]; required?: boolean }[]> = {
  members: [
    { key: "email",       label: "Email",        hints: ["email","e-mail","emailaddress","mail"], required: true },
    { key: "full_name",   label: "Full name",    hints: ["name","fullname","member","client","clientname"] },
    { key: "first_name",  label: "First name",   hints: ["first","firstname","givenname","forename"] },
    { key: "last_name",   label: "Last name",    hints: ["last","lastname","surname","familyname"] },
    { key: "phone",       label: "Phone",        hints: ["phone","mobile","cell","telephone","contact"] },
    { key: "joined_on",   label: "Joined",       hints: ["joined","joindate","created","signup","startdate","memberSince"] },
    { key: "status",      label: "Status",       hints: ["status","active","state"] },
  ],
  memberships: [
    { key: "email",             label: "Member email", hints: ["email","e-mail","mail"], required: true },
    { key: "plan",              label: "Plan name",    hints: ["plan","membership","package","product","service"], required: true },
    { key: "status",            label: "Status",       hints: ["status","state"] },
    { key: "starts_on",         label: "Starts",       hints: ["start","startdate","purchased","begin"] },
    { key: "expires_on",        label: "Expires",      hints: ["expiry","expires","expiration","enddate","end"] },
    { key: "price_cents",       label: "Price paid",   hints: ["price","amount","paid","total","cost"] },
    { key: "credits_remaining", label: "Credits left", hints: ["credits","remaining","sessionsleft","balance"] },
  ],
  attendance: [
    { key: "email",       label: "Member email", hints: ["email","e-mail","mail"], required: true },
    { key: "attended_at", label: "Visit date",   hints: ["date","visit","attended","checkin","checkedin","classdate"], required: true },
  ],
};

/** First guess at which column is which, from the header row. */
export function guessMapping(type: string, headers: string[]): Record<string, string> {
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z]/g, "");
  const out: Record<string, string> = {};
  const taken = new Set<string>();

  // Exact matches are claimed first, across every field, before anything is
  // allowed to match on a substring. One pass lets a loose hint steal a column
  // that a later field names exactly — "end" is a substring of "attendance",
  // so expires_on would take the attendance column out from under the field
  // that actually is it. Hints are normalised on both sides, or a hint written
  // in camelCase can never match anything.
  for (const pass of ["exact", "loose"] as const) {
    for (const f of FIELDS[type] ?? []) {
      if (out[f.key]) continue;
      const hit = headers.find(
        (h) =>
          !taken.has(h) &&
          f.hints.some((x) =>
            pass === "exact" ? norm(h) === norm(x) : norm(h).includes(norm(x)),
          ),
      );
      if (hit) { out[f.key] = hit; taken.add(hit); }
    }
  }
  return out;
}
