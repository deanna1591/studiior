#!/usr/bin/env bash
#
# Compare every function definition in `public` between the local replay of the
# migration files and the hosted database.
#
# WHY THIS EXISTS: `supabase migration list` records THAT a version ran, never
# WHICH. It showed all seventy applied and agreed with itself while two
# functions differed from their files, because both migrations had been edited
# in place after they had already been applied. That cost three sessions.
#
# WHY IT FAILS LOUDLY: the first version of this script captured the hosted
# fetch with `2>/dev/null` and no exit check, so a failed fetch produced an
# empty list and every local function was reported as diverged. A tool that
# reports everything as diverged is worse than no tool, because nobody reads the
# second one. It now refuses to compare unless BOTH sides were read.
#
#   ./scripts/check-hosted-drift.sh                 compare local with hosted
#   ./scripts/check-hosted-drift.sh --self-test     prove the comparison itself
#
# Exit 1 for DIFFERENT — same signature, different body — and ALSO for a
# function missing on hosted when no local migration is waiting to explain it.
# "Missing" is only innocent while there is something unpushed that would create
# it; with nothing unpushed it is the same fault one step further along, which
# is exactly the state this tool found on its first honest run.

set -uo pipefail

TMPDIR_SELF=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SELF"' EXIT
PARSE_ERR="$TMPDIR_SELF/parse.err"
CLI_ERR="$TMPDIR_SELF/cli.err"
READ_NOTE=""

LOCAL_DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
PARSER="$(dirname "$0")/parse-db-rows.py"

# One query for both sides. The last row is an INTEGRITY ROW — the row count and
# a checksum of the rows themselves — so a value the CLI's table renderer wrapped
# or truncated is caught by the parser instead of being reported as drift. Every
# time displayed by this tool is a definition hash and nothing else; there is no
# clock in here.
FN_SQL="
with f as (
  select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||md5(pg_get_functiondef(p.oid)) as v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select v as h from (
  select v, 0 as k from f
  union all
  select '#guard|'||count(*)||'|'||md5(coalesce(string_agg(v, chr(10) order by v), '')), 1 from f
) t order by k, h;"

# rls_auto_enable is installed by the Supabase platform and exists on hosted
# only. The expect_*/login/sig helpers are created by the TEST SUITES, so a
# local database that has run them carries functions no migration defines.
SKIP='^(rls_auto_enable|expect_[a-z_]*|expect|login|sig|psig)\('

die() { printf '%s\n' "$*" >&2; exit 2; }

# Which local migrations hosted has not applied. A function missing on hosted is
# ordinary when one of these would create it, and is drift when the list is
# empty. Left blank when the CLI could not answer, and a blank list is reported
# as unknown rather than as innocent.
UNPUSHED=""
UNPUSHED_KNOWN=0
read_unpushed() {
  local out
  out=$(supabase migration list --linked 2>/dev/null) || return 0
  UNPUSHED=$(printf '%s' "$out" | python3 -c '
import sys, json, re
raw = sys.stdin.read(); i = raw.find("{")
if i >= 0:
    try:
        d = json.loads(raw[i:])
        print(" ".join(m["local"] for m in d.get("migrations", [])
                       if m.get("local") and not m.get("remote")))
        raise SystemExit(0)
    except SystemExit: raise
    except Exception: pass
# Table form: a local version in the first column and an empty remote column.
out = []
for line in raw.splitlines():
    m = re.match(r"^\s*[|\u2502]\s*(\d{14})\s*[|\u2502]\s*([^|\u2502]*)[|\u2502]", line)
    if m and not m.group(2).strip():
        out.append(m.group(1))
print(" ".join(out))
') || return 0
  UNPUSHED_KNOWN=1
}

# The label for whichever route actually answered, printed with the counts so
# nobody has to guess how the numbers were obtained.
HOSTED_VIA=""

parse() {  # $1 = raw text, $2 = what produced it
  printf '%s' "$1" | python3 "$PARSER" 2>"$PARSE_ERR" | sort
  local st=("${PIPESTATUS[@]}")
  if [ "${st[1]}" -ne 0 ]; then
    die "Could not read $2.
$(cat "$PARSE_ERR")"
  fi
  # The parser reports the row count and shape on stderr; keep it for the header.
  READ_NOTE=$(tr -d '\n' < "$PARSE_ERR")
}

read_local() {
  local out
  if ! out=$(psql "$LOCAL_DB" -tAc "$FN_SQL" 2>&1); then
    die "Could not read the LOCAL database. Is \`supabase start\` running?
$out"
  fi
  parse "$out" "the LOCAL database"
}

# THREE ROUTES, tried in order, because the CLI's output format is not something
# this tool may depend on: it prints a box TABLE in an ordinary terminal, JSON
# under --output-format json, and JSON again under some sandboxes and wrappers.
# The parser reads all three; these routes exist so that a machine where the CLI
# will not cooperate at all still has a way through.
read_hosted() {
  local url raw rc

  # 1. psql straight at the hosted database. No CLI, no formatting, nothing to
  #    parse — the same route the local side uses. -w so a missing password
  #    fails instead of hanging on a prompt nobody is there to answer.
  url="${STUDIIOR_HOSTED_DB_URL:-${SUPABASE_DB_URL:-}}"
  if [ -n "$url" ]; then
    HOSTED_VIA="psql direct"
    if ! raw=$(PGCONNECT_TIMEOUT=15 psql "$url" -w -tAc "$FN_SQL" 2>&1); then
      die "Could not read the HOSTED database over psql.
$raw
Nothing has been compared — fix the connection rather than reading a diff."
    fi
    parse "$raw" "the HOSTED database (psql)"
    return
  fi

  # 2 and 3. The CLI, asking for JSON when this version has the flag, and taking
  #    whatever it gives when it does not. stdout and stderr are kept APART:
  #    "Initialising login role..." goes to stderr and merging the two is what
  #    made the first version of this script unparseable.
  local -a flags=(--linked)
  if supabase db query --help 2>&1 | grep -q -- '--output-format'; then
    flags+=(--output-format json)
    HOSTED_VIA="supabase db query --output-format json"
  else
    HOSTED_VIA="supabase db query"
  fi

  raw=$(supabase db query "${flags[@]}" "$FN_SQL" 2>"$CLI_ERR"); rc=$?
  if [ $rc -ne 0 ]; then
    die "Could not read the HOSTED database (supabase db query exited $rc).
$(cat "$CLI_ERR")
Nothing has been compared — fix the connection rather than reading a diff."
  fi

  # If the preferred route came back unreadable, try the other one before giving
  # up. Either shape is fine; only an unverifiable one is not.
  if ! printf '%s' "$raw" | python3 "$PARSER" >/dev/null 2>"$PARSE_ERR"; then
    local alt
    if [ "${#flags[@]}" -gt 1 ]; then alt=""; else alt="--output-format json"; fi
    if [ -n "$alt" ] || [ "${#flags[@]}" -gt 1 ]; then
      local raw2
      if [ -n "$alt" ]; then
        raw2=$(supabase db query --linked $alt "$FN_SQL" 2>/dev/null)
      else
        raw2=$(supabase db query --linked "$FN_SQL" 2>/dev/null)
      fi
      if printf '%s' "$raw2" | python3 "$PARSER" >/dev/null 2>/dev/null; then
        HOSTED_VIA="$HOSTED_VIA (fell back to the other output format)"
        parse "$raw2" "the HOSTED database"
        return
      fi
    fi
  fi
  parse "$raw" "the HOSTED database"
}

compare() {  # $1 = left file, $2 = right file, $3 = left label, $4 = right label
  local L="$1" R="$2" LN="$3" RN="$4" rc=0
  local t; t=$(mktemp -d)
  grep -Ev "$SKIP" "$L" | sort > "$t/l"
  grep -Ev "$SKIP" "$R" | sort > "$t/r"

  # THE SANITY GATE. One side empty while the other is not is a failed read, not
  # a database with no functions — and reporting it as total divergence is the
  # bug this rewrite exists to remove.
  if [ ! -s "$t/l" ] || [ ! -s "$t/r" ]; then
    die "One side came back empty ($LN $(wc -l < "$t/l" | tr -d ' '), $RN $(wc -l < "$t/r" | tr -d ' ')).
That is a failed read, not a divergence. Nothing has been compared."
  fi

  cut -d'|' -f1 "$t/l" | sort > "$t/lnames"
  cut -d'|' -f1 "$t/r" | sort > "$t/rnames"

  comm -23 "$t/lnames" "$t/rnames" > "$t/only_l"
  comm -13 "$t/lnames" "$t/rnames" > "$t/only_r"
  # Present on both sides, different hash: the alarm.
  comm -12 "$t/lnames" "$t/rnames" | while read -r name; do
    a=$(grep -F "$name|" "$t/l" | head -1 | cut -d'|' -f2)
    b=$(grep -F "$name|" "$t/r" | head -1 | cut -d'|' -f2)
    [ "$a" = "$b" ] || printf '%s\n' "$name"
  done > "$t/diff"

  printf '%s %s   %s %s\n' "$LN" "$(wc -l < "$t/l" | tr -d ' ')" \
                           "$RN" "$(wc -l < "$t/r" | tr -d ' ')"

  if [ -s "$t/diff" ]; then
    rc=1
    printf '\nDIFFERENT — same signature, different body (%s)\n' "$(wc -l < "$t/diff" | tr -d ' ')"
    printf '  This is the fault this tool exists for: a migration edited after it\n'
    printf '  was applied. Fix forward with a new migration.\n'
    sed 's/^/    /' "$t/diff"
  fi
  if [ -s "$t/only_l" ]; then
    printf '\nMISSING ON %s (%s)\n' \
      "$(printf '%s' "$RN" | tr '[:lower:]' '[:upper:]')" "$(wc -l < "$t/only_l" | tr -d ' ')"
    if [ "$UNPUSHED_KNOWN" -eq 0 ]; then
      printf '  Whether a migration is waiting to create these is UNKNOWN —\n'
      printf '  `supabase migration list --linked` could not be read. Check it.\n'
    elif [ -n "$UNPUSHED" ]; then
      printf '  Ordinary if one of the unpushed migrations creates them: %s\n' "$UNPUSHED"
    else
      rc=1
      printf '  DRIFT. Hosted has applied every local migration and these still\n'
      printf '  do not exist there, so the migration that defines them was edited\n'
      printf '  after it applied. Fix forward with a new migration.\n'
    fi
    sed 's/^/    /' "$t/only_l"
  fi
  if [ -s "$t/only_r" ]; then
    printf '\nONLY ON %s (%s)\n' \
      "$(printf '%s' "$RN" | tr '[:lower:]' '[:upper:]')" "$(wc -l < "$t/only_r" | tr -d ' ')"
    sed 's/^/    /' "$t/only_r"
  fi
  if [ ! -s "$t/diff" ] && [ ! -s "$t/only_l" ] && [ ! -s "$t/only_r" ]; then
    printf '\nIN STEP: every function definition matches.\n'
  fi
  rm -rf "$t"
  return $rc
}

if [ "${1:-}" != "--self-test" ]; then read_unpushed; fi

if [ "${1:-}" = "--self-test-formats" ] || [ "${1:-}" = "--self-test" ]; then
  # PROVES THE READING, on a machine that gets a TABLE as well as one that gets
  # JSON. The local database stands in for hosted — this is about the shape of
  # the output, not about which database produced it — and psql renders the very
  # same query in each of the shapes the CLI is known to print.
  t=$(mktemp -d)
  psql "$LOCAL_DB" -tAc "$FN_SQL" 2>/dev/null | python3 "$PARSER" 2>/dev/null | sort > "$t/want"
  [ -s "$t/want" ] || { echo "SELF-TEST FAILED: could not read the local database"; exit 2; }
  echo "baseline: $(wc -l < "$t/want" | tr -d ' ') functions read from bare psql output"

  fmt_case() {  # $1 = label, $2... = psql -P settings
    local label="$1"; shift
    local args=() setting
    for setting in "$@"; do args+=(-P "$setting"); done
    psql "$LOCAL_DB" "${args[@]}" -c "$FN_SQL" 2>/dev/null > "$t/raw"
    if ! python3 "$PARSER" < "$t/raw" 2>/dev/null | sort > "$t/got"; then
      echo "  FAIL  $label — the parser refused output it should have read"; return 1
    fi
    if cmp -s "$t/want" "$t/got"; then
      echo "  ok    $label — $(wc -l < "$t/got" | tr -d ' ') functions, identical to the baseline"
    else
      echo "  FAIL  $label — parsed a DIFFERENT set than the baseline"; return 1
    fi
  }

  fails=0
  echo "--- shapes that must be read correctly"
  fmt_case "unicode box table (what the CLI prints in a terminal)" \
           "linestyle=unicode" "border=2" || fails=1
  fmt_case "ASCII table"      "linestyle=ascii" "border=2" || fails=1
  fmt_case "psql default aligned table" "border=1" || fails=1
  # JSON, built from the baseline, in the shape --output-format json produces.
  python3 -c '
import json, sys
rows = [{"h": l.rstrip("\n")} for l in open(sys.argv[1])]
print(json.dumps({"rows": rows}))' "$t/want" > "$t/raw"
  # the integrity row has to travel with it, exactly as the database sends it
  psql "$LOCAL_DB" -tAc "$FN_SQL" 2>/dev/null | grep '^#guard|' > "$t/guard"
  python3 -c '
import json, sys
rows = [{"h": l.rstrip("\n")} for l in open(sys.argv[1])] + [{"h": open(sys.argv[2]).read().strip()}]
print(json.dumps({"rows": rows}))' "$t/want" "$t/guard" > "$t/raw"
  if python3 "$PARSER" < "$t/raw" 2>/dev/null | sort | cmp -s - "$t/want"; then
    echo "  ok    JSON (--output-format json, and sandbox wrappers)"
  else
    echo "  FAIL  JSON"; fails=1
  fi

  echo "--- shapes that must be REFUSED rather than reported as drift"
  # A renderer that wraps long cells: the classic way a table mangles a value.
  psql "$LOCAL_DB" -P format=wrapped -P columns=60 -P border=2 -c "$FN_SQL" 2>/dev/null > "$t/raw"
  if python3 "$PARSER" < "$t/raw" >/dev/null 2>"$t/err"; then
    echo "  FAIL  wrapped table was accepted — mangled values would be reported as drift"; fails=1
  else
    echo "  ok    wrapped table refused: $(head -1 "$t/err")"
  fi
  # A truncated read: the transport dropped the tail.
  psql "$LOCAL_DB" -P linestyle=unicode -P border=2 -c "$FN_SQL" 2>/dev/null | head -20 > "$t/raw"
  if python3 "$PARSER" < "$t/raw" >/dev/null 2>"$t/err"; then
    echo "  FAIL  truncated output was accepted"; fails=1
  else
    echo "  ok    truncated output refused: $(head -1 "$t/err")"
  fi
  # One character changed inside one row: the checksum has to notice.
  psql "$LOCAL_DB" -tAc "$FN_SQL" 2>/dev/null | sed '2s/[0-9a-f]$/0/' > "$t/raw"
  if python3 "$PARSER" < "$t/raw" >/dev/null 2>"$t/err"; then
    echo "  FAIL  a corrupted row was accepted"; fails=1
  else
    echo "  ok    corrupted row refused: $(head -1 "$t/err")"
  fi

  rm -rf "$t"
  if [ "$fails" -ne 0 ]; then echo; echo "FORMAT SELF-TEST FAILED"; exit 2; fi
  echo; echo "FORMAT SELF-TEST PASSED: table, ASCII, JSON and bare all read alike;"
  echo "wrapped, truncated and corrupted output are refused."
  [ "${1:-}" = "--self-test-formats" ] && exit 0
  echo
fi

if [ "${1:-}" = "--self-test" ]; then
  # Proves the COMPARISON, without touching production: local against a copy of
  # itself must be silent, and one altered function must be the only thing it
  # names.
  t=$(mktemp -d)
  read_local > "$t/a"
  cp "$t/a" "$t/b"
  echo "--- identical snapshots (must be IN STEP)"
  compare "$t/a" "$t/b" local copy || { echo "SELF-TEST FAILED: reported a difference between identical inputs"; exit 2; }
  echo
  echo "--- one function's body altered (must name exactly that one)"
  victim=$(grep -Ev "$SKIP" "$t/a" | head -1 | cut -d'|' -f1)
  awk -v v="$victim" -F'|' 'BEGIN{OFS="|"} $1==v {$2="deadbeefdeadbeefdeadbeefdeadbeef"} {print}' "$t/a" > "$t/c"
  out=$(compare "$t/a" "$t/c" local altered); rc=$?
  printf '%s\n' "$out"
  n=$(printf '%s\n' "$out" | sed -n '/^DIFFERENT/,/^$/p' | grep -c '^    ')
  if [ "$rc" -eq 1 ] && [ "$n" -eq 1 ] && printf '%s' "$out" | grep -qF "    $victim"; then
    echo; echo "SELF-TEST PASSED: exactly one function reported, and it is the one altered."
  else
    echo; echo "SELF-TEST FAILED: expected exactly 1 DIFFERENT ($victim), got $n (exit $rc)"; exit 2
  fi
  rm -rf "$t"; exit 0
fi

T=$(mktemp -d)
read_local  > "$T/local"
read_hosted > "$T/hosted"
printf 'hosted read via: %s — %s\n' "$HOSTED_VIA" "$READ_NOTE"
compare "$T/local" "$T/hosted" local hosted
rc=$?
rm -rf "$T"
exit $rc
