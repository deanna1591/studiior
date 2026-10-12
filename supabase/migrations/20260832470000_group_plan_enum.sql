-- Decision 76 (76a) — the 'group' enum values, ALONE.
--
-- The enum trap: a new enum value cannot be USED in the same transaction that
-- adds it (proven repeatedly — migrations 036, 077, 175, 196, 204, 206, 228).
-- So the two values land here and the build is the next migration (480000).
--
--   plan_type.'group'      — a group package plan (Barkada).
--   payment_source.'group' — a seat booked as part of a group (no credit).
--
-- Schema/data only: no function is defined here.

alter type plan_type      add value if not exists 'group';
alter type payment_source add value if not exists 'group';
