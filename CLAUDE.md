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

Three migrations, applying clean from `supabase db reset`:

- **001** schema: 47 tables, 110 RLS policies, grants for `authenticated` and `service_role`
- **002** `book_class()`: the booking transaction — occurrence locked `for update`, §2.1 eligibility gate in order with a specific reason code per failure, §2.2 payment source resolution, waitlist, booking + `credit_ledger` + `booked_count` in one transaction
- **003** `bookings.override_reason` / `overridden_rules` (§2.3 visibility), and `p_payment_source` so §2.4 comp bookings are reachable

Three suites, **113 assertions**, all passing from a clean `db reset`:

| Suite | Asserts | Covers |
|---|---|---|
| `test/rls_test.sql` | 36 | tenant isolation, role boundaries, restricted views |
| `test/book_class_test.sql` | 57 | authorisation, gate reason codes, payment resolution, overrides, comp |
| `test/booking_concurrency_test.sql` | 20 | 50 simultaneous bookings against a 10-seat class |

`supabase/seed.sql` runs automatically on `db reset` and seeds Reform Collective as tenant one — **synthetic data only**, every address `@example.com`. One studio, one location, two rooms, four class types, three instructors, owner/manager/front-desk/instructor logins, four plans, a thirteen-class week materialised 26 weeks back and 4 weeks forward, and 30 members across six cohorts with attendance to match. The cohorts exist so the AI features have something real to read: five members drifting into `retention_risk`, four `new_member_stalled`, one `past_due` membership, four who never returned after one class. Attendance is generated from a deterministic hash rather than `random()`, so every reset produces an identical database and a misbehaving query can be reproduced.

No application code yet.

**Next:** one vertical slice — staff schedule → create class → member books → front desk checks in.

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

**An applied migration is immutable.** Once a migration has run against a hosted Supabase project, it is history: fix forward with a new migration, never edit the file in place. A hosted database records which migrations it has applied and will not replay an edited one, so the file and the live schema silently diverge — and every environment that already ran the old version keeps it.

Until something is actually hosted, editing in place is safe and `db reset` replays from scratch, so migration 002's authorisation predicate was corrected in the file rather than patched over. **That grace expires the first time a migration reaches a hosted project.** After that the rule is absolute, including for a comment.

---

## Stack

Supabase (Postgres, RLS per tenant) · Next.js (staff app + member PWA) · Stripe Connect Standard, studio's own account — money never touches the platform · Vercel, auto-deploy on push.

Staff app at `app.studiior.com`. Member PWA at `{studio}.studiior.app`, per-studio branding, no app store. Notifications are email plus web push only; iOS push works post-install only.

---

## Workflow

```bash
supabase start                 # local stack
supabase db reset              # drop, replay all migrations, run supabase/seed.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/rls_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/book_class_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/booking_concurrency_test.sql
```

`db reset` before every test run. Testing against accumulated local state hides migrations that fail on a clean install. The suites use disjoint UUID spaces and email domains, so they can run in any order after one reset — but each will refuse to run twice without a reset, because its own fixtures are already there.

Migrations need timestamp filenames (`YYYYMMDDHHMMSS_name.sql`) or the CLI skips them silently, which looks exactly like a push that worked.

Never run any of the three suites against production. They create roles, insert fixtures, and the concurrency suite opens 50 connections.

---

## Known issues

`btree_gist` internals throw grant warnings on every `db reset`. Cosmetic. Fix by scoping grants to own functions rather than `all functions in schema public`.
