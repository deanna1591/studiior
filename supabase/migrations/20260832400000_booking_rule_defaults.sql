-- =============================================================================
-- Decision 71 (settings surfacing) — three live booking columns get an editor.
--
-- studio_settings.booking_cutoff_minutes, max_future_bookings and
-- waitlist_enabled have been enforced in book_class (and its successors) since
-- the beginning but had NO settings editor — they sat in audit rule 3's skip
-- set. This migration only changes the DEFAULT of booking_cutoff_minutes and
-- adds shape CHECKs; the UI + registry (app side) make them editable.
--
-- NO DATA UPDATE — existing studios keep their stored values. The default was 0
-- (book until the class starts); a fresh studio now defaults to closing bookings
-- 30 minutes before the start, a saner out-of-the-box value. Reform and every
-- existing studio keep their 0 until an owner changes it. No function is defined
-- here (schema only), so the migration carries no function manifest header.
-- =============================================================================

-- A newly provisioned studio closes bookings 30 minutes before the class.
alter table studio_settings alter column booking_cutoff_minutes set default 30;

-- Shape CHECKs, added only if not already present (confirmed absent). A cut-off
-- is 0..1440 minutes (0 = book right up to the start, a day at most); a forward
-- cap is null (unlimited) or 1..100.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'studio_settings_booking_cutoff_sane'
       and conrelid = 'public.studio_settings'::regclass)
  then
    alter table studio_settings
      add constraint studio_settings_booking_cutoff_sane
        check (booking_cutoff_minutes between 0 and 1440);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'studio_settings_max_future_sane'
       and conrelid = 'public.studio_settings'::regclass)
  then
    alter table studio_settings
      add constraint studio_settings_max_future_sane
        check (max_future_bookings is null or max_future_bookings between 1 and 100);
  end if;
end $$;
