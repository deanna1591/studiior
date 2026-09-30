#!/usr/bin/env bash
#
# The amendment-9 sweep: a SECURITY DEFINER function must never call a GUARDED
# function whose guard checks the CALLER's identity. A definer runs as its owner
# but auth.uid()/is_manager_up()/auth_instructor_id() still reflect the ORIGINAL
# caller, so a definer that does work on behalf of somebody other than that
# caller (an anon webhook, a trigger, a sweep, or a loop over OTHER instructors)
# hits the guard and raises PT403/PT401 for a request it should have allowed.
# award_conversion_bonus_run calling the guarded member_first_class was one;
# request_cover's offer loop calling the guarded instructor_available_at was
# another (Decision 45).
#
# WHAT IT FLAGS: every SECURITY DEFINER function whose body calls a function
# whose guard checks the CALLER's SUBJECT IDENTITY — i.e. a guard that raises
# PT403/PT401 using `auth_instructor_id` (is this the instructor?), OR any
# function that has an `_run` twin (the member-ownership class amendment 9 hit,
# e.g. member_first_class, whose guard compares a member's user_id to auth.uid()).
#
# WHY NOT "any PT403 raiser": a role guard (is_manager_up) or a service guard
# (is_service_context) tests the caller's OWN stable role, so it does not misfire
# when a definer runs on behalf of somebody else — a manager RPC calling a
# manager-guarded helper passes, a service sweep calling a service helper passes.
# The guards that misfire are the SUBJECT-identity ones: when a definer loops
# over OTHER instructors (request_cover) or activates on behalf of another member
# (amendment 9), auth_instructor_id / user_id=auth.uid() no longer match. Flagging
# every PT403 raiser would report ~85 sites, ~84 of them benign role/service
# passes, and bury the one that bites. member-ownership null-guards are covered
# separately by scripts/check-null-guards.py.
#
# A hit not in the allowlist is a FAILURE (exit 1). Reads the newest definitions
# from the LIVE local database.
#
#   ./scripts/check-guarded-callers.sh
#
# Triage each hit:
#   - internal/definer calling a guard where the guard would wrongly fire (the
#     caller runs on behalf of a different subject, or as anon/service) → give
#     the guarded function an unguarded `_run` twin and call that.
#   - a member/staff-facing path where the guard IS the point (the caller only
#     ever reaches it as a principal the guard accepts, having checked first)
#     → allowlist it in scripts/guarded-callers-allow.txt with a one-line reason.
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
  "select p.proname, p.prosecdef, pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f';" \
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
    # in a comment (e.g. "assign_instructors() only ever...") is not a false hit,
    # and a PT403 written in a comment does not mark a function self-guarded.
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", " ", sql)
    return sql

# proname -> {"secdef": bool, "bodies": [stripped, ...]}
funcs = {}
with open(rows_path, newline="") as f:
    for row in csv.reader(f):
        if len(row) < 3:
            continue
        name, secdef, body = row[0], row[1], strip_comments(row[2])
        e = funcs.setdefault(name, {"secdef": False, "bodies": []})
        if secdef.strip().lower() in ("t", "true"):
            e["secdef"] = True
        e["bodies"].append(body)

names = set(funcs)
# A guard raises PT403/PT401; a SUBJECT-identity guard also names auth_instructor_id
# (the instructor-is-this-caller test that misfires on a foreign instructor).
guard_re = re.compile(r"errcode\s*=\s*'PT40[13]'")
subj_re  = re.compile(r"auth_instructor_id")
has_twin = {n for n in names if (n + "_run") in names}
# Flag callees that are subject-guarded, OR that have an _run twin (the
# member-ownership class the _run pattern already marks — keep catching it).
self_guarded = {
    n for n, e in funcs.items()
    if n in has_twin
    or any(guard_re.search(b) and subj_re.search(b) for b in e["bodies"])
}

allow = set()
try:
    with open(allow_path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                allow.add(re.sub(r"\s+", "", line))  # "a -> b" -> "a->b"
except FileNotFoundError:
    pass

# Flag: a SECURITY DEFINER caller whose body calls a self-guarded function.
call_re = {g: re.compile(r"(?<![A-Za-z0-9_])" + re.escape(g) + r"\s*\(") for g in self_guarded}
hits = set()
for caller, e in funcs.items():
    if not e["secdef"]:
        continue                       # a SECURITY INVOKER caller runs the guard as itself — fine
    for g in self_guarded:
        if caller == g:
            continue
        if any(call_re[g].search(b) for b in e["bodies"]):
            hits.add((caller, g))

report = sorted(hits)
if report:
    print("guarded-caller sweep — a SECURITY DEFINER function calls a self-guarded function:")
    for c, g in report:
        allowed = f"{c}->{g}" in allow
        fix = f"call {g}_run" if g in has_twin else f"needs a {g}_run twin, or allowlist"
        print(f"  {c} -> {g}  ({fix}){'   [allowlisted]' if allowed else ''}")
else:
    print("guarded-caller sweep: no SECURITY DEFINER function calls a self-guarded function — clean.")

unallowed = [(c, g) for (c, g) in report if f"{c}->{g}" not in allow]
if unallowed:
    print(f"FAIL: {len(unallowed)} unallowlisted guarded-caller(s) — call the unguarded twin, or allowlist with a reason.")
    sys.exit(1)
sys.exit(0)
PY
