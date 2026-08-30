# Adding these files to the repo

Unpack into `~/Desktop/studiior-dev`, keeping the folder structure:

    CLAUDE.md              -> repo root
    docs/*.md              -> new docs/ folder

`supabase/migrations/` and `test/` already exist in your repo — the copies
here are for reference only. Don't overwrite your local migration; it has
the grants fix applied.

Then:

    git add -A
    git commit -m "Add specs and CLAUDE.md"

Claude Code reads CLAUDE.md automatically on open.
