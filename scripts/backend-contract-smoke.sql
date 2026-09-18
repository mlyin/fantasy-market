-- Transaction-only integration check of the existing RPC contract. Leaves no users,
-- leagues, trades or balances behind. Run with a database administrator connection.
begin;
do $$
declare
  seller uuid := gen_random_uuid(); buyer uuid := gen_random_uuid();
  result jsonb; lid uuid; cid uuid; oid uuid; bid uuid; membership public.league_members;
begin
  insert into auth.users(id, raw_user_meta_data) values
    (seller, '{"display_name":"Contract test seller"}'),
    (buyer, '{"display_name":"Contract test buyer"}');
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', seller::text, true);
  result := public.create_demo_league('Rollback contract test', array['Team A','Team B']);
  lid := (result->>'league_id')::uuid;
  select id into cid from public.contracts where league_id=lid order by ticker limit 1;
  perform public.seed_complete_set(lid, 10);
  oid := public.place_order(cid, 'sell', 40::smallint, 5);
  if (select reserved_quantity from public.positions where user_id=seller and contract_id=cid) <> 5 then
    raise exception 'sell reservation mismatch';
  end if;

  perform set_config('request.jwt.claim.sub', buyer::text, true);
  if exists(select 1 from public.leagues where id=lid) then raise exception 'nonmember can read private league'; end if;
  membership := public.join_league(result->>'invite_code');
  membership := public.join_league(result->>'invite_code');
  if membership.league_id <> lid or membership.cash_balance <> 1000000 then raise exception 'join mismatch'; end if;
  bid := public.place_order(cid, 'buy', 50::smallint, 3);
  if not exists(select 1 from public.trades where buy_order_id=bid and price_cents=40 and quantity=3) then
    raise exception 'maker-price fill mismatch';
  end if;
  if (select remaining from public.orders where id=oid) <> 2 then raise exception 'partial fill mismatch'; end if;
  if (select reserved_cash from public.league_members where user_id=buyer and league_id=lid) <> 0 then
    raise exception 'buyer reservation not released';
  end if;
  begin
    perform public.settle_league(lid,cid);
    raise exception 'noncommissioner settled market';
  exception when raise_exception then
    if sqlerrm <> 'commissioner only or already settled' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', seller::text, true);
  perform public.cancel_order(oid);
  if (select reserved_quantity from public.positions where user_id=seller and contract_id=cid) <> 0 then
    raise exception 'cancel did not release shares';
  end if;
  perform public.settle_league(lid,cid);
  if (select cash_balance from public.league_members where user_id=buyer and league_id=lid) <> 1000180 then
    raise exception 'settlement cash mismatch';
  end if;
  if (select quantity from public.positions where user_id=buyer and contract_id=cid) <> 3 then
    raise exception 'expected historical positions retained after payout';
  end if;
end $$;
rollback;
select 'PASS: join, RLS, reservations, maker-price fill, cancellation and settlement; all test data rolled back' as result;
