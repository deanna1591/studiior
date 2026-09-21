-- Decision 35, Part A — new checkin_method values, ALONE.
--
-- A new enum value cannot be USED in the transaction that adds it (the recorded
-- enum trap, migrations 036/077), so 'instructor' and 'import' are added here and
-- used only by the NEXT migration (import_commit switches to 'import' so that
-- 'staff' means a human at the desk) and by Part B (an instructor scan writes
-- 'instructor'). 'self' already exists (migration 001) and Part A finally writes
-- it. 'kiosk' also already exists and stays unused (the kiosk role is deferred).

alter type checkin_method add value if not exists 'instructor';
alter type checkin_method add value if not exists 'import';
