-- Additive extension to the existing market schema. Legacy leagues keep working.
alter table public.contracts
  add column manager_name text check (manager_name is null or length(btrim(manager_name)) between 1 and 100),
  add column claimed_by uuid,
  add constraint contracts_claimed_member_fk foreign key (league_id, claimed_by)
    references public.league_members(league_id, user_id),
  add constraint contracts_one_team_per_member unique (league_id, claimed_by);

create schema if not exists market_private;
revoke all on schema market_private from public, anon;
grant usage on schema market_private to authenticated;

-- A private definer performs the atomic write. Public RPC wrappers are invokers.
create function market_private.create_roster_league(p_name text, p_roster jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  l public.leagues;
  entry jsonb;
  i integer := 0;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 100 then
    raise exception 'Enter a league name of 1–100 characters';
  end if;
  if p_roster is null or jsonb_typeof(p_roster) <> 'array' then raise exception 'Roster must be a list'; end if;
  if jsonb_array_length(p_roster) not between 2 and 32 then raise exception 'Add 2–32 teams'; end if;
  for entry in select value from jsonb_array_elements(p_roster) loop
    if coalesce(jsonb_typeof(entry->'team'), '') <> 'string'
       or coalesce(jsonb_typeof(entry->'manager'), '') <> 'string'
       or length(btrim(entry->>'team')) not between 1 and 100
       or length(btrim(entry->>'manager')) not between 1 and 100 then
      raise exception 'Every team needs a team name and manager name (1–100 characters)';
    end if;
  end loop;
  if (select count(distinct lower(btrim(value->>'team'))) from jsonb_array_elements(p_roster)) <> jsonb_array_length(p_roster) then
    raise exception 'Team names must be unique';
  end if;
  l := public.create_league(btrim(p_name), 1000000);
  for entry in select value from jsonb_array_elements(p_roster) loop
    i := i + 1;
    insert into public.contracts(league_id, name, ticker, manager_name)
      values(l.id, btrim(entry->>'team'), 'T'||i::text, btrim(entry->>'manager'));
  end loop;
  return jsonb_build_object('league_id', l.id, 'invite_code', l.invite_code);
end $$;

create function public.create_roster_league(p_name text, p_roster jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select market_private.create_roster_league(p_name, p_roster)
$$;

create function market_private.claim_roster_team(p_contract uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.contracts;
  lid uuid;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'authentication required'; end if;
  select league_id into lid from public.contracts where id = p_contract;
  if lid is null or not exists(select 1 from public.league_members where league_id=lid and user_id=uid) then
    raise exception 'Join this league before choosing a team';
  end if;
  -- Serialize claims within one league, including concurrent choices on two devices.
  perform 1 from public.leagues where id=lid for update;
  select * into c from public.contracts where id=p_contract;
  if c.manager_name is null then raise exception 'This team has no roster identity'; end if;
  if c.claimed_by = uid then return; end if; -- safe retry after a lost response
  if c.claimed_by is not null then raise exception 'Someone already claimed this team. Choose another.'; end if;
  if exists(select 1 from public.contracts where league_id=lid and claimed_by=uid) then
    raise exception 'You already chose your team in this league';
  end if;
  update public.contracts set claimed_by=uid where id=p_contract;
end $$;

create function public.claim_roster_team(p_contract uuid)
returns void language sql security invoker set search_path = '' as $$
  select market_private.claim_roster_team(p_contract)
$$;

-- Also enforce identity for old clients: order/position writes cannot trade before
-- a roster member is selected. Existing leagues with no roster are unaffected.
create function market_private.require_roster_identity()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from public.contracts where league_id=new.league_id and manager_name is not null)
     and not exists(select 1 from public.contracts where league_id=new.league_id and claimed_by=new.user_id) then
    raise exception 'Choose your team before trading in this league';
  end if;
  return new;
end $$;
create trigger orders_require_roster_identity before insert on public.orders
  for each row execute function market_private.require_roster_identity();
create trigger positions_require_roster_identity before insert on public.positions
  for each row execute function market_private.require_roster_identity();

revoke all on function market_private.create_roster_league(text,jsonb),
  market_private.claim_roster_team(uuid), market_private.require_roster_identity(),
  public.create_roster_league(text,jsonb), public.claim_roster_team(uuid) from public, anon, authenticated;
grant execute on function market_private.create_roster_league(text,jsonb),
  market_private.claim_roster_team(uuid), public.create_roster_league(text,jsonb),
  public.claim_roster_team(uuid) to authenticated;
-- No table-write grants or row-visibility policies change. Existing contracts RLS
-- restricts roster names and claims to members of that league.
