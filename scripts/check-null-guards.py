#!/usr/bin/env python3
"""
Catch the null-guard ownership bug before it ships.

THE BUG (migrations 020, 035, 129, 130): a guard `if not ( m.user_id = auth.uid()
or is_desk_up(...) ) then raise` does NOT fire when m.user_id is NULL — every
unclaimed guest, lead and import — because `null = auth.uid()` is NULL, `NULL or
false` is NULL, and `if NULL then raise` is skipped. Any signed-in user can then
act on that member's row at any studio.

THE RULE: a guard comparing a nullable column to auth.uid() wraps it in
exists(select 1 ... where col = auth.uid()) or coalesce(col = auth.uid(), false).
Never a bare equality inside `if ... then`.

SCOPE, stated honestly. This catches exactly the auth.uid() ownership idiom —
an `if`-guard that compares something to auth.uid() with `=`/`<>` and contains
neither coalesce nor exists. That is where all four known instances lived, and
it is a pure text check, no parsing. It does NOT catch an arbitrary nullable
column compared to a non-auth.uid() value (e.g. `if a.x = b.y then raise`); that
would need paren- and schema-aware parsing, which this deliberately does not do.
So: green here means the auth.uid() ownership guards are all safe, not that no
NULL can ever fall through any guard anywhere.

Usage:
  scripts/check-null-guards.py            # scan the local DB (after `supabase db reset`)
  scripts/check-null-guards.py --self-test
Env: STUDIIOR_LOCAL_DB_URL overrides the default local connection.
"""
import os, re, subprocess, sys

URL = os.environ.get("STUDIIOR_LOCAL_DB_URL",
                     "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

def dump_functions():
    q = ("select '===FUNC:'||p.oid::regprocedure||E'\\n'||pg_get_functiondef(p.oid) "
         "from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
         "where n.nspname='public' and p.prokind='f' order by 1;")
    out = subprocess.run(["psql", URL, "-tAc", q], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"could not read functions: {out.stderr.strip()}")
    funcs, cur, body = {}, None, []
    for line in out.stdout.splitlines():
        if line.startswith("===FUNC:"):
            if cur is not None:
                funcs[cur] = "\n".join(body)
            cur, body = line[len("===FUNC:"):], []
        elif cur is not None:
            body.append(line)
    if cur is not None:
        funcs[cur] = "\n".join(body)
    return funcs

# An `if`-guard is `if ... then`, possibly spanning lines. Compare-to-auth.uid
# in a bare form: `= auth.uid()` or `auth.uid() =` (and the `<>` variants).
GUARD = re.compile(r"\bif\b(.*?)\bthen\b", re.IGNORECASE | re.DOTALL)
AUTHCMP = re.compile(r"(=|<>)\s*auth\.uid\(\)|auth\.uid\(\)\s*(=|<>)", re.IGNORECASE)

def _strip_comments(text):
    # Prose in `--` line comments and `/* */` blocks contains "if"/"then" and
    # would let the guard regex over-span and swallow real guards. Remove them.
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"--[^\n]*", " ", text)
    # `end if` contains the word "if"; left alone, `\bif\b` matches it and the
    # guard regex over-spans from there, swallowing the real guard before it.
    text = re.sub(r"\bend\s+if\b", "end_if", text, flags=re.IGNORECASE)
    return text

def offenders_in(body):
    body = _strip_comments(body)
    hits = []
    for m in GUARD.finditer(body):
        guard = m.group(1)
        if not AUTHCMP.search(guard):
            continue
        # A real if-CONDITION has no statement separator and no subquery. If the
        # captured span contains one, the regex crossed a statement boundary or
        # the comparison sits inside a subquery WHERE (`where col = auth.uid()`,
        # which is null-SAFE — a NULL there just excludes the row). And the two
        # null-safe idioms, coalesce()/exists(), are exactly what we want to see.
        if ";" in guard: continue
        if re.search(r"\b(select|insert|update|delete|coalesce|exists)\b", guard, re.IGNORECASE): continue
        hits.append(" ".join(guard.split())[:160])
    return hits

def scan(funcs):
    bad = {}
    for name, body in funcs.items():
        h = offenders_in(body)
        if h:
            bad[name] = h
    return bad

def self_test():
    ok = True
    bad_snippet = "begin if not (m.user_id = auth.uid() or is_desk_up(x)) then raise; end if; end"
    if not offenders_in(bad_snippet):
        print("SELF-TEST FAIL: did not flag a bare `= auth.uid()` guard"); ok = False
    for safe in [
        "begin if not (coalesce(m.user_id = auth.uid(), false) or is_desk_up(x)) then raise; end if; end",
        "begin if not (exists (select 1 from members m where m.user_id = auth.uid())) then raise; end if; end",
        "begin select 1 from members where user_id = auth.uid(); end",  # WHERE clause, not a guard
        "begin if (select count(*) from members where user_id = auth.uid()) > 0 then raise; end if; end",  # subquery WHERE, null-safe
    ]:
        if offenders_in(safe):
            print(f"SELF-TEST FAIL: flagged a safe form: {safe}"); ok = False
    print("SELF-TEST: pass" if ok else "SELF-TEST: FAIL")
    return 0 if ok else 1

def main():
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    bad = scan(dump_functions())
    if not bad:
        print("IN STEP: no bare `= auth.uid()` ownership guards — all use exists() or coalesce().")
        sys.exit(0)
    print("NULL-GUARD BUG: these guards compare to auth.uid() without coalesce()/exists(),")
    print("so a NULL column makes the raise fall through (see migrations 020/035/129/130):\n")
    for name, hits in sorted(bad.items()):
        for h in hits:
            print(f"  {name}\n     {h}\n")
    sys.exit(1)

if __name__ == "__main__":
    main()
