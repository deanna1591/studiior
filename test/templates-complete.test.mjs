// Decision 80 (f): every notification template is on the Templates page. The
// keys are read from the migrations themselves (every insert into
// notification_templates, less every delete), so a new template that is not
// listed in lib/templates.mjs fails here before it ships. Keys only the SQL
// test suites create are excluded.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { TEMPLATE_GROUPS } from "../lib/templates.mjs";

const TEST_ONLY = new Set(["flex_cancelled", "flex_confirmed"]);

function migrationTemplateKeys() {
  const dir = new URL("../supabase/migrations/", import.meta.url);
  const keys = new Set();
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".sql")).sort()) {
    const sql = fs.readFileSync(new URL(f, dir), "utf8");
    // Walk the statements in file order so a later delete removes an earlier insert.
    const re = /(insert\s+into\s+(?:public\.)?notification_templates\s*\([^)]*\)[\s\S]*?;\s*$)|(delete\s+from\s+(?:public\.)?notification_templates\s+where\s+key\s*(?:=|in)\s*\(?([^;]*?)\)?\s*;)/gim;
    let m;
    while ((m = re.exec(sql))) {
      if (m[1]) {
        for (const t of m[1].matchAll(/(?:\(\s*|select\s+)'([a-z0-9_]+)'\s*,/gi)) keys.add(t[1]);
      } else if (m[3]) {
        for (const t of m[3].matchAll(/'([a-z0-9_]+)'/g)) keys.delete(t[1]);
      }
    }
  }
  for (const k of TEST_ONLY) keys.delete(k);
  return keys;
}

test("every notification template has a Templates page entry", () => {
  const listed = new Set(TEMPLATE_GROUPS.flatMap((g) => g.keys.map((k) => k.key)));
  const missing = [...migrationTemplateKeys()].filter((k) => !listed.has(k)).sort();
  assert.deepEqual(missing, [], `templates with no page entry: ${missing.join(", ")}`);
});

test("the page lists no template the migrations do not create", () => {
  const made = migrationTemplateKeys();
  const extra = TEMPLATE_GROUPS.flatMap((g) => g.keys.map((k) => k.key)).filter((k) => !made.has(k)).sort();
  assert.deepEqual(extra, [], `page entries with no template: ${extra.join(", ")}`);
});

test("every entry has a plain title, an audience and a when line", () => {
  for (const g of TEMPLATE_GROUPS) for (const k of g.keys) {
    assert.ok(k.label && k.when, k.key);
    assert.ok(["Members", "Instructors", "Staff"].includes(k.audience), k.key);
  }
});
