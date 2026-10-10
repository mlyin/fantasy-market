-- Administrator connection only; all fixtures and mutations are rolled back.
begin;
do $$
declare
  uid uuid := gen_random_uuid(); result jsonb; lid uuid; cid uuid; before_cash bigint;
begin
  insert into auth.users(id, raw_user_meta_data) values (uid, '{"display_name":"QA guards"}');
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  result := public.create_demo_league('Rollback beta guards', array['Alpha','Beta']);
  lid := (result->>'league_id')::uuid;
  select id into cid from public.contracts where league_id=lid order by ticker limit 1;
  perform public.seed_complete_set(lid, 10);
  begin
    perform public.add_contract(lid,'Late team','LATE');
    raise exception 'late contract accepted';
  exception when raise_exception then
    if sqlerrm <> 'Teams are fixed once a roster is imported or trading starts' then raise; end if;
  end;
  begin
    perform public.place_order(cid,'buy',50::smallint,1000001);
    raise exception 'oversize order accepted';
  exception when raise_exception then
    if sqlerrm <> 'invalid order' then raise; end if;
  end;
  reset role;
  update public.leagues set status='closed' where id=lid;
  set local role authenticated;
  begin
    perform public.place_order(cid,'buy',50::smallint,1);
    raise exception 'closed league order accepted';
  exception when raise_exception then
    if sqlerrm <> 'market unavailable' then raise; end if;
  end;
  begin
    perform public.seed_complete_set(lid,1);
    raise exception 'closed league sets accepted';
  exception when raise_exception then
    if sqlerrm <> 'market unavailable' then raise; end if;
  end;
  perform public.settle_league(lid,cid);
  select cash_balance into before_cash from public.league_members where league_id=lid and user_id=uid;
  begin
    perform public.settle_league(lid,cid);
    raise exception 'duplicate settlement accepted';
  exception when raise_exception then
    if sqlerrm <> 'commissioner only or already settled' then raise; end if;
  end;
  if before_cash <> 1000000 or before_cash <> (select cash_balance from public.league_members where league_id=lid and user_id=uid) then
    raise exception 'settlement paid wrong amount';
  end if;
  reset role;
  if has_function_privilege('anon','public.place_order(uuid,public.order_side,smallint,bigint)','execute')
     or has_function_privilege('anon','market_private.settle_league(uuid,uuid)','execute') then
    raise exception 'unauthenticated mutation access';
  end if;
end $$;
rollback;
select 'PASS: fixed team set, quantity limits, closed-market rejection, duplicate settlement, RPC grants; all fixtures rolled back' as result;
