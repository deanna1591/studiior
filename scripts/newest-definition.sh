#!/usr/bin/env bash
# newest-definition.sh <function_name>
#
# Prints the NEWEST migration file that DEFINES a SQL function, and the line.
# "Newest" = highest timestamp filename (migrations sort chronologically), so
# `tail -1` on a SORTED list is the current definition — the one to rebuild from.
#
# Match is case-insensitive and covers both hand-written and pg_get_functiondef
# forms: `function <name>(` and `function public.<name>(`. This is the tool for
# the rebuild rule in CLAUDE.md: run it every time a function is re-issued.
# Written because book_class was once rebuilt from a stale base (`tail -1` on
# UNSORTED grep output) and record_document's uppercase `FUNCTION public.` form
# was missed by a case-sensitive grep — both real, both caught only by suites.
set -euo pipefail

name="${1:-}"
if [ -z "$name" ]; then
  echo "usage: $(basename "$0") <function_name>" >&2
  exit 2
fi

dir="$(cd "$(dirname "$0")/.." && pwd)/supabase/migrations"
if [ ! -d "$dir" ]; then
  echo "no migrations directory at $dir" >&2
  exit 2
fi

# "function <name>(" or "function public.<name>(", any case, any spacing. This
# matches CREATE/DROP/ALTER of the function and NOT a bare call site (which has
# no preceding "function" keyword).
pat="function[[:space:]]+(public\.)?${name}[[:space:]]*\("

# Files that define it, sorted by filename (timestamp); the last is newest.
newest="$(grep -rilE "$pat" "$dir"/*.sql 2>/dev/null | sort | tail -1 || true)"
if [ -z "$newest" ]; then
  echo "no definition of '${name}' found in $dir" >&2
  exit 1
fi

# The CREATE line specifically (not a drop/grant/revoke that also names it). Fall
# back to the last matching line if no CREATE is found in the file.
create="create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?function[[:space:]]+(public\.)?${name}[[:space:]]*\("
line="$(grep -inE "$create" "$newest" | tail -1 | cut -d: -f1 || true)"
if [ -z "$line" ]; then
  line="$(grep -inE "$pat" "$newest" | tail -1 | cut -d: -f1)"
fi
text="$(sed -n "${line}p" "$newest" | sed 's/^[[:space:]]*//')"

echo "newest definition of '${name}':"
echo "  ${newest}:${line}"
echo "  ${text}"
