-- Migration 175 — Decision 40 Part A: add 'xendit' to the payment_provider enum.
--
-- ALONE in its own migration. A value added to an enum cannot be USED in the same
-- transaction that adds it, and the Supabase CLI runs each migration file in one
-- transaction — so every reference to 'xendit'::payment_provider lives in the NEXT
-- file (20260831810000_xendit_adapter.sql). This is the enum trap (see migration 036,
-- pending_payment_status, and 169 checkin_method_values).
--
-- payment_provider was created 'manual' | 'stripe' in migration 040 (manual_payments).
-- Xendit becomes the second online adapter under Decision 16 (payments are
-- provider-agnostic; a Xendit payment activates through the same activate_purchase()).

alter type payment_provider add value if not exists 'xendit';
