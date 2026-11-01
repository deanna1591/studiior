-- Decision 89 — Studio messages: the sender_kind enum, carried alone.
--
-- A new enum value cannot be USED in the transaction that adds the value, and a
-- new enum TYPE used by a table in the same transaction is fine — but keeping the
-- type in its own migration matches the project's enum convention (036/077/175/
-- 204/206) and leaves the next migration free to reference it without a caveat.
-- Schema only; no functions.

create type message_sender_kind as enum ('member', 'staff');
