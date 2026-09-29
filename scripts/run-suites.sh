#!/usr/bin/env bash
#
# Run the SQL test suites, each against its OWN clean `supabase db reset`.
#
# WHY THIS EXISTS: the suites share a UUID space per file but NOT the schema —
# a handful assert schema-level facts (the anon surface is exactly ten) or take
# unfiltered global counts, so running them all on one reset lets an earlier
# suite's leftovers pass or fail a later one. The honest gate is one reset per
# suite. This is the gate before every push; it should not live in a scrollback.
#
# WHY IT WAITS FOR READINESS: `supabase db reset` can return before the database
# is actually serving the replayed schema, and a suite that connects in that gap
# fails with "relation \"public.profiles\" does not exist" — a race, not a real
# failure, that once made a green run look red. So each iteration checks the
# reset's exit status AND then polls until `public.profiles` resolves before it
# runs the suite. A reset that fails, or never becomes ready, is a FAILED suite,
# never a skipped one.
#
#   ./scripts/run-suites.sh                 every suite in test/, own reset each
#   ./scripts/run-suites.sh test/foo.sql …  only the named suites
#
# Exit 0 only when every suite ran and passed; exit 1 if any reset failed, any
# database never became ready, or any suite raised (ON_ERROR_STOP) or printed a
# FAIL line.

set -uo pipefail

DB="${STUDIIOR_LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
READY_TIMEOUT="${READY_TIMEOUT:-90}"   # seconds to wait for the schema after a reset
# A PLAIN progress file, one line per suite AS IT COMPLETES, so a check running
# while the gate is in flight can `tail` it and say "41 of 63 done". The summary
# on stdout is often piped through `tail`, which buffers until the run ends and
# shows nothing mid-run; this file is written and flushed per suite instead.
PROGRESS_LOG="${RUN_SUITES_PROGRESS:-/tmp/run-suites-progress.log}"
cd "$(dirname "$0")/.."

# Suites to run: the arguments, or every file in test/.
if [ "$#" -gt 0 ]; then
  suites=("$@")
else
  suites=(test/*.sql)
fi
total=${#suites[@]}

# Truncate the progress file and record the run's shape up front, so a reader
# knows the denominator before the first suite finishes.
: > "$PROGRESS_LOG" 2>/dev/null || PROGRESS_LOG=/dev/null
printf 'run-suites: 0/%d done — started %s\n' "$total" "$(date '+%H:%M:%S')" >> "$PROGRESS_LOG"

# One line per completed suite: "12/63  ok    test/foo.sql". Appended and
# flushed immediately (>> is unbuffered), so `tail -f` follows it live.
progress() {
  local status="$1" file="$2" done=$((pass + fail))
  printf '%d/%d  %-4s %s\n' "$done" "$total" "$status" "$file" >> "$PROGRESS_LOG"
}

# Wait until psql can resolve public.profiles (schema replayed and serving), or
# give up after READY_TIMEOUT seconds. Returns non-zero on timeout.
wait_ready() {
  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if [ "$(psql "$DB" -tAc "select to_regclass('public.profiles') is not null" 2>/dev/null)" = "t" ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

pass=0
fail=0
failed=()

for f in "${suites[@]}"; do
  if [ ! -f "$f" ]; then
    echo "!!! MISSING: $f"
    fail=$((fail + 1)); failed+=("$f"); progress "MISS" "$f"; continue
  fi

  if ! supabase db reset >/tmp/run-suites-reset.log 2>&1; then
    echo "!!! RESET FAILED before $f — not run against a half-built database"
    tail -3 /tmp/run-suites-reset.log | sed 's/^/    /'
    fail=$((fail + 1)); failed+=("$f"); progress "FAIL" "$f"; continue
  fi

  if ! wait_ready; then
    echo "!!! DATABASE NEVER READY within ${READY_TIMEOUT}s before $f"
    fail=$((fail + 1)); failed+=("$f"); progress "FAIL" "$f"; continue
  fi

  out=$(psql "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1)
  if echo "$out" | grep -qiE "ERROR:|FAIL "; then
    echo "!!! FAIL: $f"
    echo "$out" | grep -iE "ERROR:|FAIL " | head -3 | sed 's/^/    /'
    fail=$((fail + 1)); failed+=("$f"); progress "FAIL" "$f"
  else
    echo "ok: $f"
    pass=$((pass + 1)); progress "ok" "$f"
  fi
done

printf 'run-suites: %d/%d done — %d clean, %d failed\n' "$((pass + fail))" "$total" "$pass" "$fail" >> "$PROGRESS_LOG"
echo "=== $pass clean, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed[*]}"
  exit 1
fi
