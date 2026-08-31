-- =============================================================================
-- MIGRATION 031 — wiring §12's events to the things that cause them
--
-- Triggers, not call sites. A booking is made from the member app, the staff
-- roster, a walk-in and a waitlist acceptance, and a notification that depends
-- on every one of those callers remembering to queue it is a notification that
-- will be missed by the next caller somebody writes.
--
-- Safe as triggers because queue_notification() is idempotent — the dedupe key
-- is deterministic — and because it checks preferences itself, so a trigger
-- cannot send something a member opted out of.
--
-- What is NOT wired here, and why: class_cancelled, instructor_substituted and
-- payment_failed all have queueing functions and no caller, because cancelling
-- an occurrence, substituting an instructor and a Stripe webhook are three
-- features that do not exist yet. The functions are tested; they fire the day
-- those screens land. Saying so beats a trigger on a table nothing writes.
-- =============================================================================

create function tg_queue_booking_notifications() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Demo data never emails anybody. Checked on the MEMBER, not the booking:
  -- generate_demo_data() books through book_class() and only sets is_demo on
  -- the booking afterwards, so at insert time the flag is still false and the
  -- trigger had already queued seventy-four confirmations to invented people.
  -- The member is flagged before any of their bookings exist.
  if new.is_demo
     or exists (select 1 from members m where m.id = new.member_id and m.is_demo) then
    return new;
  end if;

  -- Covers a fresh booking and a waitlist place being accepted, which is an
  -- UPDATE into 'booked' rather than an insert.
  if new.status = 'booked'
     and (tg_op = 'INSERT' or old.status is distinct from 'booked') then
    perform queue_booking_notifications(new.id);
  end if;
  return new;
end $$;

create trigger bookings_queue_notifications
  after insert or update of status on bookings
  for each row execute function tg_queue_booking_notifications();

create function tg_queue_waitlist_offer() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform queue_waitlist_offer(new.id);
  return new;
end $$;

create trigger waitlist_offers_queue_notification
  after insert on waitlist_offers
  for each row execute function tg_queue_waitlist_offer();

-- A cancelled booking should not still be reminded about. §12 has no line for
-- this because it is not an event — it is the absence of one.
create function tg_cancel_booking_notifications() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('cancelled','late_cancelled')
     and old.status is distinct from new.status then
    update notifications
       set status = 'cancelled'
     where status = 'scheduled'
       and dedupe_key in ('booking_confirmed:' || new.id, 'class_reminder:' || new.id);
  end if;
  return new;
end $$;

create trigger bookings_cancel_notifications
  after update of status on bookings
  for each row execute function tg_cancel_booking_notifications();

-- -----------------------------------------------------------------------------
-- Credit expiry — a daily sweep, because "7 days before" is a date, not an event
-- -----------------------------------------------------------------------------
create function queue_all_credit_expiries() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not is_service_context() then
    raise exception 'the expiry sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;
  for r in select id from studios where status = 'active' loop
    n := n + queue_credit_expiries(r.id);
  end loop;
  return jsonb_build_object('queued', n);
end $$;
revoke execute on function queue_all_credit_expiries() from public;
grant execute on function queue_all_credit_expiries() to service_role;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron missing; credit expiry warnings will not queue.';
    return;
  end if;
  create extension if not exists pg_cron;
  if exists (select 1 from cron.job where jobname = 'studiior-credit-expiry') then
    perform cron.unschedule('studiior-credit-expiry');
  end if;
  -- Hourly, not daily: expires_on is compared in each studio's own timezone, so
  -- "seven days before" arrives at a different UTC moment for each of them.
  perform cron.schedule('studiior-credit-expiry', '7 * * * *',
    $job$select queue_all_credit_expiries()$job$);
end $$;
