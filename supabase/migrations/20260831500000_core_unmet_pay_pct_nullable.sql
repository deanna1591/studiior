-- 145: the core holding fee is a PAIR, and either half may be absent.
--
-- migration 138 gave core a flat slot-holding fee (`core_unmet_pay_cents`,
-- nullable) beside the percentage (`core_unmet_pay_pct`), and the pay compute
-- resolves them as alternatives:
--
--   coalesce(core_unmet_pay_cents, base * coalesce(core_unmet_pay_pct, 0) / 100)
--
-- so a flat amount wins where set and the percentage is the fallback. But the
-- percentage column was NOT NULL DEFAULT 50, so "we pay a flat ₱400 and have no
-- percentage" could not be stored — the settings form required the percentage
-- and refused the blank its own help text documented ("leave it blank to use
-- the percentage"). Reform Collective pays a flat fee and has no percentage.
--
-- Drop NOT NULL so the two are true alternatives: null flat OR null pct is
-- allowed, and the form validates at least one is set rather than requiring
-- both. The compute already tolerates a null pct (the coalesce above), and the
-- DEFAULT of 50 stays — a new studio still gets 50, inert until guarantees is
-- on, so the all_off canary and the defaults sweep are unaffected. The range
-- CHECK (`between 0 and 100`) passes on null, so it is unchanged. This is
-- schema only; no function is re-issued and no ACL is touched.

alter table studio_settings
  alter column core_unmet_pay_pct drop not null;

comment on column studio_settings.core_unmet_pay_pct is
  'The core holding rate as a percentage of base, the FALLBACK where '
  'core_unmet_pay_cents (a flat amount) is null. Null here means no percentage: '
  'the flat amount is then the only holding fee, and the form requires that at '
  'least one of the two is set. Default 50 for a studio that turns guarantees '
  'on without choosing; inert while guarantees is off.';
