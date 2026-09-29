#!/usr/bin/env bash
#
# The amendment-9 sweep: an INTERNAL SQL function must never call a GUARDED
# wrapper. award_conversion_bonus_run called member_first_class (guarded) instead
# of member_first_class_run (internal), so it raised PT403 for every real caller
# — the anon webhook and the authenticated-member belt — and no test caught it,
# because the suites run as a superuser where the guard passes.
#
# This finds every guarded/internal PAIR (a function X that has an X_run twin)
# and reports every OTHER function whose body calls the GUARDED name X( — a call
# an internal should make to X_run instead. A hit not in the allowlist is a
# FAILURE (exit 1). Reads the newest definitions from the LIVE local database
# (pg_get_functiondef), not the migration files in order.
#
#   ./scripts/check-guarded-callers.sh
#
# Allowlist: scripts/guarded-callers-allow.txt, one "caller -> guarded" per line
# with a reason after '#'. Exit 0 clean or all-allowlisted, 1 on an unallowlisted
# hit, 2 if the database could not be read.

set -uo pipefail
DB="${STUDIIOR_LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
cd "$(dirname "$0")/.."
ALLOW="scripts/guarded-callers-allow.txt"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if ! psql "$DB" --csv -tc \
  "select p.proname, pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f';" \
  > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
  echo "check-guarded-callers: could not read functions from $DB" >&2
  exit 2
fi

python3 - "$tmp" "$ALLOW" <<'PY'
import sys, csv, re
rows_path, allow_path = sys.argv[1], sys.argv[2]
csv.field_size_limit(10 ** 7)

def strip_comments(sql):
    # Drop -- line comments and /* */ block comments so a guarded name mentioned
    # in a comment (e.g. "assign_instructors() only ever...") is not a false hit.
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", " ", sql)
    return sql

funcs = {}  # proname -> [body, ...] (overloads), comments stripped
with open(rows_path, newline="") as f:
    for row in csv.reader(f):
        if len(row) < 2:
            continue
        funcs.setdefault(row[0], []).append(strip_comments(row[1]))

names = set(funcs)
# A guarded/internal pair: X exists AND X_run exists. X is the guarded wrapper.
guarded = sorted(n for n in names if (n + "_run") in names)

allow = set()
try:
    with open(allow_path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                allow.add(re.sub(r"\s+", "", line))  # "a -> b" -> "a->b"
except FileNotFoundError:
    pass

hits = set()
for g in guarded:
    pat = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(g) + r"\s*\(")
    for caller, bodies in funcs.items():
        if caller == g:            # the wrapper's own definition (header is g(...))
            continue
        if any(pat.search(b) for b in bodies):
            hits.add((caller, g))

report = sorted(hits)
if report:
    print("guarded-caller sweep — a function calls a guarded wrapper:")
    for c, g in report:
        allowed = f"{c}->{g}" in allow
        print(f"  {c} -> {g} (should call {g}_run){'   [allowlisted]' if allowed else ''}")
else:
    print("guarded-caller sweep: no function calls a guarded wrapper — clean.")

unallowed = [(c, g) for (c, g) in report if f"{c}->{g}" not in allow]
if unallowed:
    print(f"FAIL: {len(unallowed)} unallowlisted guarded-caller(s) — call the _run internal, or allowlist with a reason.")
    sys.exit(1)
sys.exit(0)
PY
