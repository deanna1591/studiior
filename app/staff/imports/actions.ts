"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { FIELDS, detectDateOrder, guessMapping, normalizeDate, parseCsv, splitName } from "@/lib/csv";

export type ImportState = { error: string } | null;

const DATE_FIELDS = new Set(["joined_on", "starts_on", "expires_on", "attended_at"]);

/**
 * Upload: parse, stash the raw rows, and guess the mapping.
 *
 * Nothing is judged here and nothing outside import_rows is written — the file
 * becomes rows, and the owner gets to correct the guess before anything else
 * happens.
 */
export async function uploadImport(_prev: ImportState, fd: FormData): Promise<ImportState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const type = String(fd.get("type") ?? "");
  if (!FIELDS[type]) return { error: "Pick what this file contains." };

  const file = fd.get("file") as File | null;
  if (!file || file.size === 0) return { error: "Choose a CSV file." };
  if (file.size > 8_000_000) return { error: "That file is over 8 MB. Split it and import in parts." };

  const rows = parseCsv(await file.text());
  if (rows.length < 2) return { error: "That file has a header but no rows." };

  const headers = rows[0].map((h) => h.trim());
  const body = rows.slice(1);

  const supabase = createClient();
  const { data: imp, error } = await supabase
    .from("imports")
    .insert({
      studio_id: ctx.studioId,
      type,
      filename: file.name,
      status: "uploaded",
      mapping: { headers, guessed: guessMapping(type, headers) },
      row_count: body.length,
      created_by: ctx.userId,
    })
    .select("id")
    .single();

  if (error) {
    return /row-level security/i.test(error.message)
      ? { error: "Importing is owners and managers only." }
      : { error: error.message };
  }

  // The raw row is kept verbatim. When a mapping turns out wrong, remapping
  // re-reads these rather than asking for the file again.
  const payload = body.map((cells, i) => ({
    import_id: imp.id,
    row_number: i + 1,
    raw: Object.fromEntries(headers.map((h, c) => [h, cells[c] ?? ""])),
    status: "pending",
  }));

  for (let i = 0; i < payload.length; i += 500) {
    const { error: e } = await supabase.from("import_rows").insert(payload.slice(i, i + 500));
    if (e) return { error: `Row ${i + 1}: ${e.message}` };
  }

  redirect(`/imports/${imp.id}`);
}

/**
 * Apply a mapping to every stored row, then ask the database to judge them.
 *
 * Normalisation happens here because it is string work — dates, names, money —
 * and validation happens in import_dry_run() because it needs the studio's
 * existing members and plans.
 */
export async function runDryRun(_prev: ImportState, fd: FormData): Promise<ImportState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const id = String(fd.get("id") ?? "");
  const supabase = createClient();

  const { data: imp } = await supabase
    .from("imports").select("id, type, mapping").eq("id", id).maybeSingle();
  if (!imp) return { error: "That import no longer exists." };

  const mapping: Record<string, string> = {};
  for (const f of FIELDS[imp.type] ?? []) {
    const col = String(fd.get(`map_${f.key}`) ?? "");
    if (col) mapping[f.key] = col;
  }
  for (const f of FIELDS[imp.type] ?? []) {
    if (f.required && !mapping[f.key]) return { error: `${f.label} has to come from a column.` };
  }
  if (imp.type === "members" && !mapping.full_name && !mapping.first_name && !mapping.last_name) {
    return { error: "Map a name column — either a full name, or first and last." };
  }

  const { data: rows } = await supabase
    .from("import_rows").select("id, raw").eq("import_id", id).order("row_number");
  if (!rows?.length) return { error: "That import has no rows." };

  // Date order is decided per column across the whole file: 03/04/2024 alone is
  // ambiguous, and guessing per row would shift some of a member's history by
  // months while leaving the rest correct.
  const orders: Record<string, ReturnType<typeof detectDateOrder>> = {};
  for (const [key, col] of Object.entries(mapping)) {
    if (DATE_FIELDS.has(key)) {
      orders[key] = detectDateOrder(rows.map((r) => String((r.raw as Record<string, string>)[col] ?? "")));
    }
  }

  for (const r of rows) {
    const raw = r.raw as Record<string, string>;
    const norm: Record<string, string> = {};
    for (const [key, col] of Object.entries(mapping)) {
      const v = (raw[col] ?? "").trim();
      if (!v) continue;
      if (DATE_FIELDS.has(key)) {
        const iso = normalizeDate(v, orders[key] ?? "iso");
        if (iso) norm[key] = key === "attended_at" ? iso : iso.slice(0, 10);
      } else if (key === "price_cents") {
        const cents = Math.round(Number(v.replace(/[^0-9.]/g, "")) * 100);
        if (Number.isFinite(cents)) norm[key] = String(cents);
      } else if (key === "full_name") {
        const [first, last] = splitName(v);
        norm.first_name = norm.first_name || first;
        norm.last_name = norm.last_name || last;
      } else if (key === "email") {
        norm[key] = v.toLowerCase();
      } else {
        norm[key] = v;
      }
    }
    await supabase.from("import_rows").update({ normalized: norm }).eq("id", r.id);
  }

  await supabase.from("imports")
    .update({ mapping: { ...(imp.mapping as object), applied: mapping, date_orders: orders } })
    .eq("id", id);

  const { error } = await supabase.rpc("import_dry_run", { p_import_id: id });
  if (error) {
    return error.code === "PT403"
      ? { error: "Importing is owners and managers only." }
      : { error: error.message };
  }

  revalidatePath(`/imports/${id}`);
  return null;
}

export async function commitImport(_prev: ImportState, fd: FormData): Promise<ImportState> {
  const supabase = createClient();
  const id = String(fd.get("id") ?? "");
  const { error } = await supabase.rpc("import_commit", { p_import_id: id });
  if (error) {
    if (error.code === "PT403") return { error: "Importing is owners and managers only." };
    if (error.code === "PT409") return { error: error.message };
    return { error: error.message };
  }
  revalidatePath("/imports"); revalidatePath(`/imports/${id}`); revalidatePath("/");
  return null;
}

export async function rollbackImport(_prev: ImportState, fd: FormData): Promise<ImportState> {
  const supabase = createClient();
  const id = String(fd.get("id") ?? "");
  const { error } = await supabase.rpc("import_rollback", { p_import_id: id });
  if (error) {
    if (error.code === "PT403") return { error: "Importing is owners and managers only." };
    // PT409 carries the "roll the later one back first" explanation.
    if (error.code === "PT409") return { error: error.message };
    return { error: error.message };
  }
  revalidatePath("/imports"); revalidatePath(`/imports/${id}`); revalidatePath("/");
  return null;
}
