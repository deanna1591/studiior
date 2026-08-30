# Vertical slice

One path, end to end, proving the architecture holds:

**staff signs in → week view → creates a class → member signs in on the studio
subdomain → books it → front desk checks them in.**

Nothing else is built. No design system, no member profile, no payments UI, no
other staff screens. Styling goes as far as legibility and stops.

---

## Run it

```bash
supabase start
```

```bash
supabase db reset
```

```bash
npm install
```

```bash
npm run dev
```

`db reset` replays all four migrations and runs `supabase/seed.sql`, which
creates Reform Collective and every login below. The slice is usable
immediately afterwards — no manual setup.

Regenerate types after any migration:

```bash
npm run gen:types
```

The four SQL suites, after a `db reset`:

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/rls_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/book_class_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/booking_concurrency_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/checkin_window_test.sql
```

---

## Two hosts, two apps

| Production | Local | App |
|---|---|---|
| `app.studiior.com` | `localhost:3000` | Staff |
| `{slug}.studiior.app` | `{slug}.localhost:3000` or `{slug}.lvh.me:3000` | Member PWA |

Reform Collective's slug is `reform`, so the member app is at
**http://reform.localhost:3000**. Both `*.localhost` and `*.lvh.me` resolve to
127.0.0.1 with no `/etc/hosts` edit; `.localhost` is the more reliable of the
two in some browsers, which is why both are accepted.

`middleware.ts` resolves the hostname, and for a member host resolves the slug
to a studio before anything renders. An unknown slug 404s:
`http://nosuchstudio.localhost:3000` → `Unknown studio "nosuchstudio"`.

---

## Logins

All passwords are `reform-dev-password`. Synthetic accounts on a local
database; they mean nothing anywhere else.

These logins are also printed on the sign-in pages themselves, but only when
`NODE_ENV === 'development'`. The condition is inline around the JSX so the
strings are eliminated from the production bundle rather than merely hidden —
if you refactor those blocks into a shared component, the credentials go back
into the JavaScript that anyone can read.

### Staff — http://localhost:3000

| Email | Role | What it can do in the slice |
|---|---|---|
| `owner@example.com` | owner | Everything |
| `manager@example.com` | manager | Week view, **create a class**, check members in |
| `frontdesk@example.com` | front_desk | Week view, check members in. **Cannot create classes** |
| `instructor@example.com` | instructor | Week view only |

### Member — http://reform.localhost:3000

| Email | Plan | What happens when they book |
|---|---|---|
| `alena.fabricated@example.com` | Unlimited monthly | `membership`, nothing consumed |
| `ivana.sampleton@example.com` | 8 a month | `membership`, one period credit — she has used this month's eight, so she currently falls through to `drop_in` |
| `nikola.simulated@example.com` | 10-class pack | `class_pack`, one credit off the soonest-expiring pack |
| `adela.nonexistent@example.com` | none, no signed waiver | Refused: *"Please sign the studio waiver before booking."* |

---

## The path

1. **Sign in** at http://localhost:3000 as `manager@example.com`.
2. **Week view.** Seeded classes, with instructor, room and `booked/capacity`.
   `← Previous` / `Next →` move by week.
3. **Create a class** → pick a class type, instructor, room, date, time,
   capacity. Date and time are studio-local (Europe/Prague) and are converted
   to UTC at the instant they refer to, so a 07:00 class stays 07:00 across a
   DST change.
4. **Member books.** At http://reform.localhost:3000 sign in as
   `nikola.simulated@example.com` and press Book. The payment source is
   resolved, never chosen.
5. **Front desk checks in.** Back on the staff app as
   `frontdesk@example.com`, open the class from the week view and press
   *Check in*.

   Check-in only works inside the §8 window — from 60 minutes before the class
   starts until 30 minutes after it ends — so for a class you can actually
   check into, create one starting in the next half hour at step 3. Outside
   the window the button reports why: *"check-in opens 60 minutes before the
   class starts"*.

   To check into a class further off, turn the window off for the studio:

   ```bash
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "update studio_settings set checkin_window_enforced = false where studio_id = '11111111-0000-0000-0000-000000000001';"
   ```

   That is the documented escape hatch, and it is also what a historical
   attendance import would use. `db reset` puts it back to `true`.

### Try the refusals

They are the interesting part, because each one is enforced by the database
rather than by the interface:

- Sign in as `frontdesk@example.com` and open `/classes/new` directly. The
  link is hidden for that role, but the URL still works and the **insert** is
  refused: *"Your role cannot create classes. Managers and owners only."* No
  role check runs in TypeScript — `occ_manager_write` refuses it.
- Sign in as `adela.nonexistent@example.com` and book anything. The `§2.1.4`
  waiver gate refuses her, with that specific reason and not a generic failure.
- Book the same class twice: `already_booked`.
- Check someone into a class that is not starting within the hour. The trigger
  from migration 007 refuses it, and refuses `service_role` too — it is a
  business rule, not a permission.

---

## How it is wired

**Every database call goes through a request-scoped client** built from the
caller's cookies (`lib/supabase/server.ts`), so RLS applies to all of it.
There is no service-role client in the codebase. A query that appears to need
one is a policy gap to close in SQL — that is what migration 004 does for the
pre-login slug lookup, rather than reaching for a key that bypasses every
policy in an unauthenticated request path.

**Booking is one RPC call.** `app/member/actions.ts` calls `book_class()` and
maps its `failure_reason` to a sentence. The eligibility gate, payment source
resolution, capacity check, credit consumption and waitlist placement are not
reimplemented in TypeScript, and must not be — they are one transaction with
the occurrence row locked.

**Types are generated**, never hand-written: `npm run gen:types`.

---

## Deliberately not done

- **The member schedule shows the next two weeks** with no paging.
- **Waitlist join works** (`book_class` handles it and the roster shows the
  queue in order), but there is no promotion flow — that is `waitlist_offers`
  and a job, not a screen.
- **Cancellation** is absent entirely.
