#!/bin/bash
# Compare every function definition between the local replay of the migration
# files and the hosted database. `supabase migration list` records THAT a
# version ran, never WHICH — it agreed with itself while two functions differed.
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -tAc "
select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||md5(pg_get_functiondef(p.oid))
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prokind='f' order by 1;" | sed '/^$/d' | sort > "$T/local"
supabase db query --linked "
select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')|'||md5(pg_get_functiondef(p.oid)) as h
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prokind='f' order by 1;" 2>/dev/null \
 | python3 -c "
import sys,json
d=json.loads(sys.stdin.read().split('Initialising login role...')[-1])
[print(r['h']) for r in d['rows']]" | sort > "$T/hosted"
echo "local $(wc -l < "$T/local")  hosted $(wc -l < "$T/hosted")"
# rls_auto_enable is installed by the platform and exists on hosted only. The
# expect_*/login/sig helpers are created by the test suites, so a local database
# that has run them carries functions no migration defines — run this against a
# clean `supabase db reset` or accept that they are filtered here.
SKIP='^(rls_auto_enable|expect|expect_[a-z]+|login|sig|psig)\('
if diff <(grep -Ev "$SKIP" "$T/local") <(grep -Ev "$SKIP" "$T/hosted") > "$T/d"; then
  echo "IN STEP: every function definition matches."
else
  echo "DIVERGED:"; awk -F'|' '/^[<>]/{print $1}' "$T/d" | sort -u
  exit 1
fi
