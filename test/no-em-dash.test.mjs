// Step 9c: no member-facing string contains an em dash.
//
// Scans string literals, template text and JSX text (never comments) in
// app/member, components/member and the lib files that produce member- or
// instructor-facing words. Staff-only lib files are listed below and skipped:
// they set staff screens, model prompts, or carry a dash as data.
// Run: node --test test/no-em-dash.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import ts from "typescript";

const ROOT = new URL("..", import.meta.url).pathname;
const DIRS = ["app/member", "components/member", "lib"];
const STAFF_ONLY_LIB = new Set([
  "lib/settings-registry.mjs", "lib/templates.mjs", "lib/plans.ts", "lib/locale.ts",
  "lib/flex-copy.mjs", "lib/banner.ts", "lib/ai-draft.mjs", "lib/invoice-pdf.ts",
  "lib/force-commit.mjs", "lib/xendit.ts", "lib/email-body.mjs", "lib/database.types.ts",
]);

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.(tsx?|mjs)$/.test(name) && !name.endsWith(".d.ts")) out.push(p);
  }
  return out;
}

function hits(file) {
  const src = readFileSync(file, "utf8");
  if (!src.includes("—")) return [];
  const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true,
    file.endsWith("x") ? ts.ScriptKind.TSX : file.endsWith(".mjs") ? ts.ScriptKind.JS : ts.ScriptKind.TS);
  const found = [];
  const visit = (n) => {
    const k = n.kind;
    let text = null;
    if (k === ts.SyntaxKind.StringLiteral || k === ts.SyntaxKind.NoSubstitutionTemplateLiteral) text = n.text;
    else if (k === ts.SyntaxKind.TemplateHead || k === ts.SyntaxKind.TemplateMiddle || k === ts.SyntaxKind.TemplateTail) text = n.text;
    else if (k === ts.SyntaxKind.JsxText) text = n.text;
    if (text && text.includes("—")) {
      const { line } = sf.getLineAndCharacterOfPosition(n.getStart(sf));
      found.push(`${relative(ROOT, file)}:${line + 1}: ${text.trim().slice(0, 80)}`);
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
  return found;
}

export function emDashHits() {
  const files = DIRS.flatMap((d) => walk(join(ROOT, d)))
    .filter((f) => !STAFF_ONLY_LIB.has(relative(ROOT, f)));
  return files.flatMap(hits);
}

test("no member-facing string contains an em dash", () => {
  const h = emDashHits();
  assert.deepEqual(h, [], `${h.length} em dash string(s):\n${h.join("\n")}`);
});
