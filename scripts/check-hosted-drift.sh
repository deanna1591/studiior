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

LOCAL_DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
FN_SQL="
select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||md5(pg_get_functiondef(p.oid)) as h
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prokind='f' order by 1;"

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
import sys, json
raw = sys.stdin.read(); i = raw.find("{")
if i < 0: sys.exit(1)
try: d = json.loads(raw[i:])
except Exception: sys.exit(1)
print(" ".join(m["local"] for m in d.get("migrations", [])
                if m.get("local") and not m.get("remote")))
') || return 0
  UNPUSHED_KNOWN=1
}

read_local() {
  local out
  if ! out=$(psql "$LOCAL_DB" -tAc "$FN_SQL" 2>&1); then
    die "Could not read the LOCAL database. Is \`supabase start\` running?
$out"
  fi
  printf '%s\n' "$out" | sed '/^$/d' | sort
}

read_hosted() {
  local out rc
  # stdout and stderr kept APART: the CLI puts "Initialising login role..." on
  # stderr and JSON on stdout, and merging them is what made the first version
  # unparseable in the first place.
  out=$(supabase db query --linked "$FN_SQL" 2>/tmp/.drift.err); rc=$?
  if [ $rc -ne 0 ]; then
    die "Could not read the HOSTED database (supabase db query exited $rc).
$(cat /tmp/.drift.err)
Nothing has been compared — fix the connection rather than reading a diff."
  fi
  printf '%s' "$out" | python3 -c '
import sys, json
raw = sys.stdin.read()
# Find the JSON object rather than splitting on a log line that may not be there.
i = raw.find("{")
if i < 0:
    sys.stderr.write("hosted returned no JSON. First 300 bytes:\n" + raw[:300] + "\n")
    sys.exit(3)
try:
    d = json.loads(raw[i:])
except json.JSONDecodeError as e:
    sys.stderr.write("hosted output is not valid JSON (%s). First 300 bytes:\n%s\n" % (e, raw[:300]))
    sys.exit(3)
rows = d.get("rows")
if rows is None:
    sys.stderr.write("hosted JSON has no rows key. Keys: %s\n" % list(d))
    sys.exit(3)
for r in rows:
    # By key when the alias came through, otherwise the single value in the row —
    # sharing one SQL string between psql and the CLI once dropped the alias and
    # this failed with KeyError rather than comparing anything wrong, which is
    # the behaviour wanted, but there is no reason to be brittle about it.
    if "h" in r:
        print(r["h"])
    elif len(r) == 1:
        print(next(iter(r.values())))
    else:
        sys.stderr.write("unexpected hosted row shape: %s\n" % list(r))
        sys.exit(3)
' | sort
  local pipe=("${PIPESTATUS[@]}")
  [ "${pipe[1]:-0}" -eq 0 ] || die "Could not parse the hosted result.
Nothing has been compared."
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
compare "$T/local" "$T/hosted" local hosted
rc=$?
rm -rf "$T"
exit $rc
