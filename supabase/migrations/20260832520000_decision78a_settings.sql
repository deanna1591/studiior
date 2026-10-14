-- Decision 78a (Convert) — the per-studio settings for the intro offer and the
-- convert sequence. All OFF / neutral by default, so a studio that turns nothing
-- on sees no change anywhere (the all_off canary).
--
-- Schema only; no functions (check-migration-manifest: nothing to list).

alter table studio_settings
  -- The plan the convert sequence promotes. Null = no offer (the sequence sends
  -- the plans page instead). A real plan of this studio; if the plan is deleted,
  -- the offer simply clears.
  add column intro_offer_plan_id uuid references membership_plans on delete set null,
  -- The length of a member's intro window, from their free class. 1..90 days.
  add column intro_offer_days int not null default 14 check (intro_offer_days between 1 and 90),
  -- When on, the offer plan is visible/buyable ONLY to a member inside their
  -- intro window; hidden from the public catalogue and refused at /buy otherwise.
  add column intro_offer_exclusive boolean not null default false,
  -- The convert sequence (78c) master switch for this studio.
  add column convert_sequence_enabled boolean not null default false,
  -- Who retention tasks are assigned to (Decision 78e). Front desk gets them only
  -- when a studio routes them there.
  add column retention_tasks_to text not null default 'owner_manager'
    check (retention_tasks_to in ('owner_manager', 'front_desk'));

comment on column studio_settings.intro_offer_plan_id is
  'Decision 78: the plan the convert sequence promotes; null = no offer.';
comment on column studio_settings.intro_offer_exclusive is
  'Decision 78: when on, the offer plan is visible/buyable only inside a member''s intro window.';
comment on column studio_settings.convert_sequence_enabled is
  'Decision 78c: the per-studio convert-sequence switch, default off.';
comment on column studio_settings.retention_tasks_to is
  'Decision 78e: owner_manager (default) or front_desk.';
