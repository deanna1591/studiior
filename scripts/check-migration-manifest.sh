#!/usr/bin/env bash
#
# A migration's header must list every function it defines, so a copied slice
# that overran into a neighbouring function is caught before it ships. Migration
# 190 re-issued commitment_pending by accident (its move_occurrence slice ran
# past move_occurrence's own terminator into commitment_pending); check-guarded-
# callers caught the symptom, this catches the cause.
#
# The header block (anywhere in the file, in a leading comment) is:
#   -- re-issues: fn_a(sig), fn_b(sig), ...
#   -- creates:   fn_c(sig), ...
# and may continue on following "--" comment lines that contain "name(".
#
# Compares the listed names against the create [or replace] function statements
# actually in the file. Exit 1 on any function defined-but-not-listed or
# listed-but-not-defined (or defined functions with no header at all). Exit 0
# when they match, or when the migration defines no functions (schema/data only).
#
#   ./scripts/check-migration-manifest.sh [path]   (default: newest migration)

set -uo pipefail
cd "$(dirname "$0")/.."
file="${1:-$(ls -1 supabase/migrations/*.sql 2>/dev/null | sort | tail -1)}"
[ -n "$file" ] && [ -f "$file" ] || { echo "manifest: no such migration file: ${file:-<none>}" >&2; exit 2; }

python3 - "$file" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path).read()

# Functions DEFINED — from code with line/block comments stripped, so a comment
# that merely mentions "create function X" is not counted.
code = re.sub(r"--[^\n]*", "", text)
code = re.sub(r"/\*.*?\*/", " ", code, flags=re.S)
defined = set(m.group(1).lower() for m in re.finditer(
    r"create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*\(",
    code, re.I))

# Functions LISTED — the "-- re-issues:" / "-- creates:" header and its "--"
# continuation lines that carry a "name(".
listed = set()
in_list = False
for raw in text.splitlines():
    ml = re.match(r"^\s*--\s*(re-issues|creates)\s*:(.*)$", raw, re.I)
    if ml:
        in_list, rest = True, ml.group(2)
    elif in_list and re.match(r"^\s*--", raw) and "(" in raw:
        rest = raw.lstrip().lstrip("-")
    else:
        in_list = False
        continue
    for name in re.findall(r"([a-z_][a-z0-9_]*)\s*\(", rest, re.I):
        listed.add(name.lower())

if not defined:
    print(f"manifest ok: {path} defines no functions (schema/data only)")
    sys.exit(0)
if not listed:
    print(f"MANIFEST FAIL: {path} defines {len(defined)} function(s) but has no "
          f"'-- re-issues:'/'-- creates:' header")
    print(f"  defines: {', '.join(sorted(defined))}")
    sys.exit(1)

missing = sorted(defined - listed)
extra = sorted(listed - defined)
if missing:
    print(f"MANIFEST FAIL: defined but NOT listed in the header "
          f"(a slice may have overrun into these): {', '.join(missing)}")
if extra:
    print(f"MANIFEST FAIL: listed in the header but NOT defined: {', '.join(extra)}")
if missing or extra:
    sys.exit(1)
print(f"manifest ok: {path} — {len(defined)} function(s), all listed in the header")
sys.exit(0)
PY
