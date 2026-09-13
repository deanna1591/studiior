-- The switch that gives challenges a door.
--
-- The rail item was gated on the studio already HAVING a challenge, which left
-- no way to create the first one — /challenges/new was reachable only by typing
-- the URL. "No trace when unused" has to leave one door, and the door is the
-- same one guarantees, seat caps, flex, peak and publication use: a
-- studio_settings switch, off by default, surfaced in Settings.
--
-- Off (the default) means no Challenges rail item and no way in — the whole
-- feature is invisible, which is the rule Decisions 24/25 set. On means the rail
-- item appears and leads to the create screen. This governs the STAFF entry
-- point only: a member sees a challenge because one is published and joinable,
-- not because a switch is on, so turning the switch off never rug-pulls a
-- member out of a challenge they have already joined.
alter table studio_settings
  add column if not exists challenges_enabled boolean not null default false;
