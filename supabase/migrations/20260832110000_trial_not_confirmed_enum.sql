-- =============================================================================
-- Decision 30 amendment (free first classes are grouped) — the release reason
-- for a provisional free seat that was not confirmed by the class's cutoff.
-- Added ALONE: a new enum value cannot be USED in the transaction that adds it
-- (the enum trap, migrations 036/077/175/196), so it ships one step ahead of
-- the build that uses it (20260832120000).
-- =============================================================================
alter type booking_release_reason add value if not exists 'trial_not_confirmed';
