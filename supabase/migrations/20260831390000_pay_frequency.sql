-- Decision 22's pay periods had a studio-configurable frequency but only a
-- days-based one (pay_period_days, fortnightly by default) and NO control to set
-- it — the suspension_enabled / horizon gap again. A studio should be able to
-- say weekly, fortnightly, monthly, or twice-monthly on set days.
--
-- The days model covers weekly (7) and fortnightly (14) but cannot express a
-- calendar month or two set days a month, so a mode is added and ensure_pay_period
-- branches on it. Default 'fortnightly' preserves every existing period exactly.

alter table studio_settings
  add column if not exists pay_period_mode text not null default 'fortnightly'
    check (pay_period_mode in ('weekly','fortnightly','monthly','semimonthly')),
  -- The second period's start day for twice-monthly (the first is the 1st). 16
  -- gives the common 1-15 / 16-end split; a studio can move it.
  add column if not exists pay_period_second_day int not null default 16
    check (pay_period_second_day between 2 and 28);

create or replace function ensure_pay_period(p_studio_id uuid, p_on date)
returns pay_periods
language plpgsql security definer set search_path = public as $function$
declare p pay_periods%rowtype; v_mode text; v_days int; v_anchor date; v_second int;
  v_start date; v_end date; v_som date; v_eom date; v_n int;
begin
  select * into p from pay_periods
   where studio_id = p_studio_id and p_on between starts_on and ends_on;
  if found then return p; end if;

  select coalesce(pay_period_mode, 'fortnightly'), coalesce(pay_period_days, 14),
         pay_period_anchor, coalesce(pay_period_second_day, 16)
    into v_mode, v_days, v_anchor, v_second
    from studio_settings where studio_id = p_studio_id;
  v_mode := coalesce(v_mode, 'fortnightly'); v_days := coalesce(v_days, 14);
  v_second := coalesce(v_second, 16);

  -- Whole days in studio-local dates throughout, never intervals on instants: a
  -- boundary that moved an hour at a clock change would put a class in the wrong
  -- period.
  v_som := date_trunc('month', p_on)::date;
  v_eom := (date_trunc('month', p_on) + interval '1 month' - interval '1 day')::date;

  if v_mode = 'monthly' then
    v_start := v_som; v_end := v_eom;
  elsif v_mode = 'semimonthly' then
    if extract(day from p_on)::int < v_second then
      v_start := v_som;                       v_end := v_som + (v_second - 2);
    else
      v_start := v_som + (v_second - 1);       v_end := v_eom;
    end if;
  else
    -- weekly (7) / fortnightly (14): days from the anchor, as before.
    if v_mode = 'weekly' then v_days := 7; elsif v_mode = 'fortnightly' then v_days := 14; end if;
    v_anchor := coalesce(v_anchor, v_som);
    v_n := floor((p_on - v_anchor)::numeric / v_days);
    v_start := v_anchor + (v_n * v_days);
    v_end := v_start + v_days - 1;
  end if;

  insert into pay_periods (studio_id, starts_on, ends_on)
  values (p_studio_id, v_start, v_end)
  on conflict (studio_id, starts_on) do update set starts_on = excluded.starts_on
  returning * into p;
  return p;
end $function$;
