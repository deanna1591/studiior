-- =============================================================================
-- Decision 47 — the enum value for "cancelled because nobody was available to
-- teach". Added in its OWN migration step: a new enum value cannot be USED in
-- the transaction that adds it (CLAUDE.md's rule; migrations 036, 077, 169,
-- 175). The function migration (20260832020000) that uses 'no_instructor'
-- follows this one.
--
-- 'no_instructor' pays nobody — there is no instructor — and that falls out of
-- the existing pay path with no change: compute_class_pay_run returns ok:false
-- when instructor_id is null, so record_class_pay writes nothing. The
-- staff-cancel wrapper refuses 'no_instructor' on a class that HAS an
-- instructor (PT422), so it is only ever stamped on an unstaffed class.
-- =============================================================================

alter type cancellation_cause add value if not exists 'no_instructor';
