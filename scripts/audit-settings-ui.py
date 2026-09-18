import subprocess, os, re, json, sys

PG = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
def cols(table):
    out = subprocess.run(["psql", PG, "-tAc",
        f"select column_name, data_type, coalesce(column_default,'') from information_schema.columns "
        f"where table_schema='public' and table_name='{table}' order by ordinal_position"],
        capture_output=True, text=True).stdout.strip().split("\n")
    return [l.split("|") for l in out if l]

# Everything a person could plausibly see or change lives here.
ROOTS = ["app", "components", "lib"]
FILES = []
for r in ROOTS:
    for dp, dn, fn in os.walk(r):
        if "node_modules" in dp: continue
        for f in fn:
            if f.endswith((".ts", ".tsx")) and not f.endswith("database.types.ts"):
                FILES.append(os.path.join(dp, f))
BLOB = {p: open(p, encoding="utf8", errors="ignore").read() for p in FILES}

# A WRITE control means the name appears as a form field or in an update/insert
# payload; a READ means it appears at all. Crude on purpose — a false "has UI"
# is the dangerous direction, so the patterns for WRITE are the strict ones.
def classify(col):
    hits_read, hits_write = [], []
    for p, s in BLOB.items():
        if col not in s: continue
        hits_read.append(p)
        if (re.search(r'name=["\']%s["\']' % re.escape(col), s)
            or re.search(r'\b%s\s*:' % re.escape(col), s)
            or re.search(r'p_%s\b' % re.escape(col), s)
            or re.search(r'["\']%s["\']\s*[,)]' % re.escape(col), s)):
            hits_write.append(p)
    return hits_read, hits_write

SKIP = {"id","studio_id","created_at","updated_at","is_demo","plan_id","member_id"}
for table in ("studio_settings", "membership_plans"):
    print("=" * 78)
    print(table.upper())
    print("=" * 78)
    none, read_only, written = [], [], []
    for name, typ, dflt in cols(table):
        if name in SKIP: continue
        r, w = classify(name)
        if not r: none.append((name, typ, dflt))
        elif not w: read_only.append((name, typ, dflt, r))
        else: written.append((name, typ, dflt, w))
    print("\n--- NO UI AT ALL: not named anywhere in app/, components/ or lib/ (%d)" % len(none))
    for n, t, d in none: print("    %-34s %-28s default %s" % (n, t, d or "-"))
    print("\n--- READ SOMEWHERE, NEVER WRITTEN (%d)" % len(read_only))
    for n, t, d, r in read_only: print("    %-34s %s" % (n, ", ".join(sorted(set(r))[:2])))
    print("\n--- HAS A WRITE PATH (%d)" % len(written))
    print("    " + ", ".join(n for n, *_ in written))
    print()

# ---------------------------------------------------------------------------
# The other half of this class of gap: a SECURITY DEFINER *writer* that a client
# can call (granted to authenticated, not anon) but that nothing in app/ ever
# calls. That is exactly the shape set_instructor_rate was in — a working,
# guarded function to set an instructor's pay, with no screen, so a studio's
# contract could not be entered. A trigger or a pure reader is not this; an
# unreachable writer with a live grant is.
# ---------------------------------------------------------------------------
def secdef_writers():
    q = ("select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
         "where n.nspname='public' and p.prosecdef "
         "and p.prorettype <> 'trigger'::regtype "
         "and has_function_privilege('authenticated', p.oid, 'execute') "
         "and not has_function_privilege('anon', p.oid, 'execute') "
         "and p.prosrc ~* '(insert into|update |delete from)' "
         "group by p.proname order by p.proname")
    out = subprocess.run(["psql", PG, "-tAc", q], capture_output=True, text=True).stdout.strip().split("\n")
    return [l.strip() for l in out if l.strip()]

def referenced(name):
    # A real app call names the function as a quoted string (an RPC), so look for
    # it quoted — crude, but a false "referenced" is the safe direction.
    needles = ('"%s"' % name, "'%s'" % name)
    return any(nd in s for s in BLOB.values() for nd in needles)

print("=" * 78)
print("SECURITY DEFINER WRITERS THE APP NEVER CALLS")
print("=" * 78)
orphans = [n for n in secdef_writers() if not referenced(n)]
print("\n--- CLIENT-CALLABLE WRITER, NO SCREEN: not named in app/ (%d)" % len(orphans))
print("    (each is granted to authenticated and writes, yet nothing calls it —")
print("     either it needs a screen, or its grant should be revoked. Check each.)")
for n in orphans:
    print("    %s" % n)
print()
