#!/usr/bin/env python3
"""
Turn whatever a database client printed into one payload string per row.

WHY THIS EXISTS: `supabase db query` prints a formatted box TABLE in an ordinary
terminal and JSON under some wrappers and flags, and the drift check was written
against the shape one machine happened to produce. A tool that only runs where it
was written is not a tool. This reads all three shapes:

    JSON     {"rows": [{"h": "..."}]}          (--output-format json, and wrappers)
    TABLE    the CLI's / psql's box output, unicode or ASCII borders
    BARE     one value per line                (psql -tA, the local side)

AND IT VERIFIES WHAT IT READ. The query appends an integrity row —
`#guard|<row count>|<md5 of the sorted rows>` — so a value the table renderer
wrapped, truncated or padded is caught here and reported as a FAILED READ. It
must never reach the comparison, because a mangled definition line is
indistinguishable from a function whose body really did change, and a tool that
cries drift is one nobody reads on the day it is right.
"""
import hashlib
import json
import re
import sys

# A payload row: an identity signature, a pipe, an md5. Anchored at both ends, so
# a fragment of a wrapped line cannot pass for a whole one.
ROW_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(.*\)\|[0-9a-f]{32}$")
GUARD_RE = re.compile(r"^#guard\|(\d+)\|([0-9a-f]{32})$")

BORDERS = "─│┌┐└┘├┤┬┴┼+-|= \t"


def fail(msg, raw):
    sys.stderr.write(msg + "\nFirst 300 bytes of what came back:\n" + raw[:300] + "\n")
    sys.exit(3)


def from_json(raw):
    i = min([p for p in (raw.find("{"), raw.find("[")) if p >= 0], default=-1)
    if i < 0:
        return None
    try:
        d = json.loads(raw[i:])
    except json.JSONDecodeError:
        return None
    rows = d.get("rows") if isinstance(d, dict) else d
    if not isinstance(rows, list):
        return None
    out = []
    for r in rows:
        if isinstance(r, dict):
            # By the alias when it came through, else the row's only value.
            out.append(r["h"] if "h" in r else next(iter(r.values())) if len(r) == 1 else None)
        else:
            out.append(r)
    return [str(v) for v in out if v is not None]


def from_table_or_bare(raw):
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or not line.strip(BORDERS):
            continue  # blank, or a rule made only of border characters
        if line[0] in "│|":
            line = line[1:]
        if line and line[-1] in "│|":
            line = line[:-1]
        out.append(line.strip())
    return out


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        fail("Nothing came back at all.", raw)

    values = from_json(raw)
    shape = "json"
    if values is None:
        values = from_table_or_bare(raw)
        shape = "table/bare"

    guard = None
    rows = []
    for v in values:
        m = GUARD_RE.match(v)
        if m:
            guard = (int(m.group(1)), m.group(2))
        elif ROW_RE.match(v):
            rows.append(v)

    if guard is None:
        fail(
            "Read %d rows as %s but found no integrity row, so what came back "
            "cannot be trusted.\nNothing has been compared." % (len(rows), shape),
            raw,
        )

    want_n, want_md5 = guard
    rows = sorted(set(rows))
    got_md5 = hashlib.md5("\n".join(rows).encode()).hexdigest()
    if len(rows) != want_n or got_md5 != want_md5:
        fail(
            "The output was TRUNCATED OR MANGLED in transit (read as %s).\n"
            "  the database sent %d rows; %d survived parsing\n"
            "  checksum expected %s, got %s\n"
            "This is a failed read, not a divergence. Nothing has been compared.\n"
            "Set STUDIIOR_HOSTED_DB_URL to a hosted connection string to bypass "
            "the CLI's formatting entirely." % (shape, want_n, len(rows), want_md5, got_md5),
            raw,
        )

    sys.stderr.write("read %d function definitions (%s)\n" % (len(rows), shape))
    print("\n".join(rows))


if __name__ == "__main__":
    main()
