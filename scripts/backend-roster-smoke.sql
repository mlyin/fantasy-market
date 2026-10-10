begin;
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); stranger uuid := gen_random_uuid();
  r jsonb; lid uuid; ca uuid; cb uuid; oid uuid; result public.league_members;
begin
  insert into auth.users(id, raw_user_meta_data) values
    (a, '{"display_name":"Roster test A"}'), (b, '{"display_name":"Roster test B"}'),
    (stranger, '{"display_name":"Roster test outsider"}');
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', a::text, true);
  begin
    perform public.create_roster_league('Bad roster', '[{"team":"Same","manager":"A"},{"team":"same","manager":"B"}]');
    raise exception 'duplicate teams accepted';
  exception when raise_exception then
    if sqlerrm <> 'Team names must be unique' then raise; end if;
  end;
  r := public.create_roster_league('Rollback roster test', '[{"team":"Alpha","manager":"Alex"},{"team":"Beta","manager":"Blair"}]');
  lid := (r->>'league_id')::uuid;
  select id into ca from public.contracts where league_id=lid and name='Alpha';
  select id into cb from public.contracts where league_id=lid and name='Beta';
  if ca is null or cb is null then raise exception 'missing roster teams'; end if;
  begin
    perform public.place_order(ca, 'buy', 40::smallint, 1);
    raise exception 'trade before claim accepted';
  exception when raise_exception then
    if sqlerrm <> 'Choose your team before trading in this league' then raise; end if;
  end;
  begin
    perform public.seed_complete_set(lid, 5);
    raise exception 'sets before claim accepted';
  exception when raise_exception then
    if sqlerrm <> 'Choose your team before trading in this league' then raise; end if;
  end;
  if (select cash_balance from public.league_members where league_id=lid and user_id=a) <> 1000000 then
    raise exception 'failed trade altered cash';
  end if;
  update public.contracts set claimed_by=a where id=ca;
  if found then raise exception 'direct claim writes bypassed RPC'; end if;
  perform public.claim_roster_team(ca);
  perform public.claim_roster_team(ca);
  begin
    perform public.claim_roster_team(cb);
    raise exception 'second team claim accepted';
  exception when raise_exception then
    if sqlerrm <> 'You already chose your team in this league' then raise; end if;
  end;
  perform public.seed_complete_set(lid, 5);
  oid := public.place_order(ca, 'sell', 40::smallint, 3);

  perform set_config('request.jwt.claim.sub', stranger::text, true);
  if exists(select 1 from public.contracts where league_id=lid) then raise exception 'roster visible to nonmember'; end if;
  begin
    perform public.claim_roster_team(cb);
    raise exception 'outsider claim accepted';
  exception when raise_exception then
    if sqlerrm <> 'Join this league before choosing a team' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', b::text, true);
  result := public.join_league(r->>'invite_code');
  begin
    perform public.claim_roster_team(ca);
    raise exception 'duplicate claim accepted';
  exception when raise_exception then
    if sqlerrm <> 'Someone already claimed this team. Choose another.' then raise; end if;
  end;
  perform public.claim_roster_team(cb);
  perform public.place_order(ca, 'buy', 50::smallint, 2);
  if not exists(select 1 from public.trades where league_id=lid and price_cents=40 and quantity=2) then
    raise exception 'claimed members cannot match';
  end if;
  if (select manager_name from public.contracts where league_id=lid and claimed_by=b) <> 'Blair' then
    raise exception 'identity did not persist';
  end if;
  perform set_config('request.jwt.claim.sub', a::text, true);
  perform public.cancel_order(oid);
  perform public.settle_league(lid, ca);
end $$;
rollback;
select 'PASS: roster validation, private roster, self-claim, duplicate prevention, idempotent retry, trade gate, matching, cancellation and settlement; rolled back' as result;
