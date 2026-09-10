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
