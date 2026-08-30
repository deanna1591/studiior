# Studiior

Multi-tenant SaaS for boutique fitness studios (Pilates, yoga, barre). Supabase + Next.js. Six-month V1, public launch 2 March 2027, ten design partners first.

Tenant one is Reform Collective, the founder's own studio. **Its data is production data.** Treat member PII accordingly from day one.

---

## Read before writing code

| File | What it governs |
|---|---|
| `docs/STUDIIOR_V1_DECISIONS.md` | Settled decisions. Canonical. Code that contradicts it is wrong. |
| `docs/STUDIIOR_V1_DATA_MODEL.md` | Every table, column, index, RLS approach, concurrency rules |
| `docs/STUDIIOR_V1_BUSINESS_RULES.md` | Booking, cancellation, waitlist, credits, memberships, challenges, AI |
| `docs/STUDIIOR_V1_PERMISSIONS.md` | Five roles against every action. Becomes RLS policies directly. |

The V1 Product Bible governs scope above all of these. If a feature isn't in Chapter 8's seven modules, it doesn't get built. Chapter 7 is the exclusion list.

The seven modules: Scheduling & Booking · Member CRM · Memberships & Payments · Your Member App · AI Morning Brief · Challenges · Reports.

---

## Current state

- Migration 001 applied: 47 tables, 110 RLS policies, grants for `authenticated` and `service_role`
- `test/rls_test.sql` passing 36/36 against the local Supabase stack
- No application code yet

**Next:** the booking transaction, then a fifty-concurrent-bookings test, then one vertical slice (staff schedule → create class → member books → front desk checks in).

---

## Rules that are not negotiable

**RLS is the security boundary.** A permission that exists only in React is not a permission. Every rule in the permissions doc is a policy. Instructor access to revenue is denied at the policy level, not by hiding menu items.

**Every table gets RLS and a grant.** RLS decides which rows; grants decide whether the role may touch the table at all. Both, or the table is either closed to everyone or open to everyone. See migration 001 §16.

**Booking runs in one transaction with a row lock.** `select ... from class_occurrences where id = $1 for update` before reading `booked_count`. Application-level check-then-insert will overbook under load and is not acceptable.

**Money is integer cents plus an ISO currency code.** Never floats.

**Time is `timestamptz` stored UTC.** Studio timezone governs display and all day boundaries. A 7am class stays 7am across DST — occurrences materialise by converting local time to UTC at generation, not by adding fixed intervals.

**Nothing AI-generated sends itself.** The model drafts, the owner approves. Hard architectural rule.

**Deletes are soft** via `status` / `archived_at`. Hard delete only for GDPR erasure.

**Credits derive from `credit_ledger`.** Never edited in place. `memberships.credits_remaining` is a cache written in the same transaction as the ledger row.

---

## Stack

Supabase (Postgres, RLS per tenant) · Next.js (staff app + member PWA) · Stripe Connect Standard, studio's own account — money never touches the platform · Vercel, auto-deploy on push.

Staff app at `app.studiior.com`. Member PWA at `{studio}.studiior.app`, per-studio branding, no app store. Notifications are email plus web push only; iOS push works post-install only.

---

## Workflow

```bash
supabase start                 # local stack
supabase db reset              # drop and replay all migrations
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/rls_test.sql
```

`db reset` before every test run. Testing against accumulated local state hides migrations that fail on a clean install.

Migrations need timestamp filenames (`YYYYMMDDHHMMSS_name.sql`) or the CLI skips them silently, which looks exactly like a push that worked.

Never run the RLS suite against production — it creates roles and inserts fixtures.

---

## Known issues

`btree_gist` internals throw grant warnings on every `db reset`. Cosmetic. Fix by scoping grants to own functions rather than `all functions in schema public`.
