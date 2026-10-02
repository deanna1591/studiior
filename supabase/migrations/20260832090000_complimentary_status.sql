-- =============================================================================
-- Decision 53 — complimentary (house) studios. The new platform_status value,
-- ALONE: a new enum value cannot be USED in the transaction that adds it, so it
-- gets its own migration step ahead of the columns, functions and UI.
-- =============================================================================
alter type platform_status add value if not exists 'complimentary';
