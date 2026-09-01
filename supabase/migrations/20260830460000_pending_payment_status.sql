-- =============================================================================
-- Migration 036: a booking that is holding a seat but is not paid for
-- =============================================================================
-- Its own migration because of a PostgreSQL rule: a value added to an enum
-- cannot be USED in the same transaction that adds it, and the Supabase CLI
-- runs each migration file in one transaction. Everything that reads or writes
-- 'pending_payment' therefore lives in 037 and 038.
--
-- WHY A STATUS AND NOT A FLAG. The alternative was `bookings.payment_pending`
-- beside status = 'booked'. Thirty-four places in this codebase filter on
-- booking status, and with a flag every one of them would go on treating an
-- unpaid booking as confirmed until somebody remembered to add `and not
-- payment_pending` — the notification trigger would send "You're booked in"
-- for a class nobody has paid for, the health score would count it as
-- attendance-in-waiting, and the member's history would list it.
--
-- As a status the default falls the right way round: everything that asks for
-- 'booked' silently stops seeing it, which is correct almost everywhere, and
-- the two places that DO need it — the member's own screen and the staff
-- roster — have to say so explicitly. Same reasoning as the column guard in
-- migration 035: make the safe answer the one you get by not thinking.
--
-- It still holds the seat. booked_count is incremented as usual, because the
-- member is in the middle of paying and taking their place away while they
-- type a card number is worse than briefly overstating how full a class is.
-- =============================================================================

alter type booking_status add value if not exists 'pending_payment';

-- -----------------------------------------------------------------------------
-- How long a member has to finish paying
--
-- A studio-visible timing rule, with the others, rather than a literal buried
-- in a cron job. Studios differ: a busy 6am reformer class wants the seat back
-- quickly, and a quiet Sunday mat class can afford to wait. 15 minutes is the
-- default because it is long enough to find a card and short enough that the
-- next person is not staring at a full class nobody is in.
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column if not exists dropin_payment_window_minutes int not null default 15;

alter table studio_settings drop constraint if exists studio_settings_dropin_window_range;
alter table studio_settings add constraint studio_settings_dropin_window_range
  check (dropin_payment_window_minutes between 5 and 120);

comment on column studio_settings.dropin_payment_window_minutes is
  'How long a drop-in booking holds its seat while the member is in Stripe '
  'Checkout. After this the sweep cancels it through cancel_booking(), so the '
  'seat is offered to the waitlist like any other cancellation. 5-120.';
