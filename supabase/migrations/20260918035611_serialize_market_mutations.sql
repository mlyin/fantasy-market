-- Serialize all balance/position mutations within each league. The league row
-- is always locked before orders, memberships or positions, including settlement.
-- Keep the existing RPC signatures; privileged implementations live off the API.

CREATE OR REPLACE FUNCTION market_private.add_contract(p_league uuid, p_name text, p_ticker text)
 RETURNS public.contracts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.contracts;
begin
 if auth.uid() is null then raise exception 'authentication required'; end if;
 perform 1 from public.leagues where id=p_league and commissioner_id=auth.uid() and status='open' for update;
 if not found then raise exception 'commissioner only or market unavailable'; end if;
 if exists(select 1 from public.positions where league_id=p_league)
    or exists(select 1 from public.orders where league_id=p_league)
    or exists(select 1 from public.contracts where league_id=p_league and manager_name is not null) then
   raise exception 'Teams are fixed once a roster is imported or trading starts';
 end if;
 insert into public.contracts(league_id,name,ticker) values(p_league,p_name,upper(p_ticker)) returning * into c;
 return c;
end $function$;

create or replace function public.add_contract(p_league uuid, p_name text, p_ticker text)
returns public.contracts language sql security invoker set search_path = ''
as $$ select market_private.add_contract(p_league, p_name, p_ticker); $$;
revoke all on function market_private.add_contract(uuid, text, text) from public, anon;
grant execute on function market_private.add_contract(uuid, text, text) to authenticated;
revoke all on function public.add_contract(uuid, text, text) from public, anon;
grant execute on function public.add_contract(uuid, text, text) to authenticated;

CREATE OR REPLACE FUNCTION market_private.cancel_order(p_order uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders; lid uuid;
begin
 if auth.uid() is null then raise exception 'authentication required'; end if;
 select league_id into lid from public.orders where id=p_order and user_id=auth.uid();
 if lid is null then raise exception 'order unavailable'; end if;
 perform 1 from public.leagues where id=lid for update;
 select * into o from public.orders where id=p_order and user_id=auth.uid() for update;
 if not found or o.status not in ('open','partially_filled') then raise exception 'order unavailable'; end if;
 if o.side='buy' then
  update public.league_members set reserved_cash=reserved_cash-o.price_cents::bigint*o.remaining where league_id=o.league_id and user_id=o.user_id;
 else
  update public.positions set reserved_quantity=reserved_quantity-o.remaining where contract_id=o.contract_id and user_id=o.user_id;
 end if;
 update public.orders set remaining=0,status='cancelled',updated_at=now() where id=p_order;
end $function$;

create or replace function public.cancel_order(p_order uuid)
returns void language sql security invoker set search_path = ''
as $$ select market_private.cancel_order(p_order); $$;
revoke all on function market_private.cancel_order(uuid) from public, anon;
grant execute on function market_private.cancel_order(uuid) to authenticated;
revoke all on function public.cancel_order(uuid) from public, anon;
grant execute on function public.cancel_order(uuid) to authenticated;

CREATE OR REPLACE FUNCTION market_private.place_order(p_contract uuid, p_side public.order_side, p_price smallint, p_quantity bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 uid uuid:=auth.uid(); lid uuid; oid uuid; need bigint; taker_remaining bigint:=p_quantity; maker record; fill_qty bigint; trade_px smallint;
begin
 if uid is null then raise exception 'authentication required'; end if;
 if p_side is null or p_price is null or p_quantity is null or p_price not between 1 and 99 or p_quantity not between 1 and 1000000 then raise exception 'invalid order'; end if;
 select league_id into lid from public.contracts where id=p_contract and status='open';
 if lid is null or not public.is_member(lid) then raise exception 'market unavailable'; end if;
 perform 1 from public.leagues where id=lid and status='open' for update;
 if not found or not exists(select 1 from public.contracts where id=p_contract and status='open') then
   raise exception 'market unavailable';
 end if;

 if p_side='buy' then
   need:=p_price::bigint*p_quantity;
   update public.league_members set reserved_cash=reserved_cash+need
   where league_id=lid and user_id=uid and cash_balance-reserved_cash>=need;
   if not found then raise exception 'insufficient cash'; end if;
 else
   insert into public.positions(league_id,contract_id,user_id,quantity) values(lid,p_contract,uid,0) on conflict do nothing;
   update public.positions set reserved_quantity=reserved_quantity+p_quantity
   where contract_id=p_contract and user_id=uid and quantity-reserved_quantity>=p_quantity;
   if not found then raise exception 'insufficient shares'; end if;
 end if;

 insert into public.orders(league_id,contract_id,user_id,side,price_cents,quantity,remaining)
 values(lid,p_contract,uid,p_side,p_price,p_quantity,p_quantity) returning id into oid;

 for maker in
   select * from public.orders
   where contract_id=p_contract and user_id<>uid and status in ('open','partially_filled')
     and side<>p_side and remaining>0
     and ((p_side='buy' and price_cents<=p_price) or (p_side='sell' and price_cents>=p_price))
   order by
     case when p_side='buy' then price_cents end asc,
     case when p_side='sell' then price_cents end desc,
     created_at asc, id asc
   for update
 loop
   exit when taker_remaining=0;
   fill_qty:=least(taker_remaining,maker.remaining);
   trade_px:=maker.price_cents;

   if p_side='buy' then
     update public.league_members set cash_balance=cash_balance-trade_px::bigint*fill_qty,
       reserved_cash=reserved_cash-p_price::bigint*fill_qty where league_id=lid and user_id=uid;
     update public.league_members set cash_balance=cash_balance+trade_px::bigint*fill_qty where league_id=lid and user_id=maker.user_id;
     update public.positions set quantity=quantity-fill_qty,reserved_quantity=reserved_quantity-fill_qty where contract_id=p_contract and user_id=maker.user_id;
     insert into public.positions(league_id,contract_id,user_id,quantity,cost_basis) values(lid,p_contract,uid,fill_qty,trade_px::bigint*fill_qty)
       on conflict(contract_id,user_id) do update set quantity=public.positions.quantity+excluded.quantity,cost_basis=public.positions.cost_basis+excluded.cost_basis;
     insert into public.trades(league_id,contract_id,buy_order_id,sell_order_id,buyer_id,seller_id,price_cents,quantity)
       values(lid,p_contract,oid,maker.id,uid,maker.user_id,trade_px,fill_qty);
   else
     update public.league_members set cash_balance=cash_balance-trade_px::bigint*fill_qty,
       reserved_cash=reserved_cash-maker.price_cents::bigint*fill_qty where league_id=lid and user_id=maker.user_id;
     update public.league_members set cash_balance=cash_balance+trade_px::bigint*fill_qty where league_id=lid and user_id=uid;
     update public.positions set quantity=quantity-fill_qty,reserved_quantity=reserved_quantity-fill_qty where contract_id=p_contract and user_id=uid;
     insert into public.positions(league_id,contract_id,user_id,quantity,cost_basis) values(lid,p_contract,maker.user_id,fill_qty,trade_px::bigint*fill_qty)
       on conflict(contract_id,user_id) do update set quantity=public.positions.quantity+excluded.quantity,cost_basis=public.positions.cost_basis+excluded.cost_basis;
     insert into public.trades(league_id,contract_id,buy_order_id,sell_order_id,buyer_id,seller_id,price_cents,quantity)
       values(lid,p_contract,maker.id,oid,maker.user_id,uid,trade_px,fill_qty);
   end if;

   update public.orders set remaining=remaining-fill_qty,
     status=case when remaining-fill_qty=0 then 'filled'::public.order_status else 'partially_filled'::public.order_status end,updated_at=now()
   where id=maker.id;
   taker_remaining:=taker_remaining-fill_qty;
 end loop;

 update public.orders set remaining=taker_remaining,
   status=case when taker_remaining=0 then 'filled'::public.order_status when taker_remaining<p_quantity then 'partially_filled'::public.order_status else 'open'::public.order_status end,
   updated_at=now() where id=oid;

 return oid;
end $function$;

create or replace function public.place_order(p_contract uuid, p_side public.order_side, p_price smallint, p_quantity bigint)
returns uuid language sql security invoker set search_path = ''
as $$ select market_private.place_order(p_contract, p_side, p_price, p_quantity); $$;
revoke all on function market_private.place_order(uuid, public.order_side, smallint, bigint) from public, anon;
grant execute on function market_private.place_order(uuid, public.order_side, smallint, bigint) to authenticated;
revoke all on function public.place_order(uuid, public.order_side, smallint, bigint) from public, anon;
grant execute on function public.place_order(uuid, public.order_side, smallint, bigint) to authenticated;

CREATE OR REPLACE FUNCTION market_private.seed_complete_set(p_league uuid, p_quantity bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n bigint; cost bigint;
begin
 if auth.uid() is null or p_quantity is null or p_quantity not between 1 and 1000000 then raise exception 'invalid request'; end if;
 if not public.is_member(p_league) then raise exception 'not a member'; end if;
 perform 1 from public.leagues where id=p_league and status='open' for update;
 if not found then raise exception 'market unavailable'; end if;
 select count(*) into n from public.contracts where league_id=p_league and status='open';
 if n=0 then raise exception 'no contracts'; end if;
 cost:=100::bigint*p_quantity;
 update public.league_members set cash_balance=cash_balance-cost
 where league_id=p_league and user_id=auth.uid() and cash_balance-reserved_cash>=cost;
 if not found then raise exception 'insufficient cash'; end if;
 insert into public.positions(league_id,contract_id,user_id,quantity,cost_basis)
 select p_league,id,auth.uid(),p_quantity,(100*p_quantity)/n from public.contracts where league_id=p_league and status='open'
 on conflict(contract_id,user_id) do update set quantity=public.positions.quantity+excluded.quantity,cost_basis=public.positions.cost_basis+excluded.cost_basis;
end $function$;

create or replace function public.seed_complete_set(p_league uuid, p_quantity bigint)
returns void language sql security invoker set search_path = ''
as $$ select market_private.seed_complete_set(p_league, p_quantity); $$;
revoke all on function market_private.seed_complete_set(uuid, bigint) from public, anon;
grant execute on function market_private.seed_complete_set(uuid, bigint) to authenticated;
revoke all on function public.seed_complete_set(uuid, bigint) from public, anon;
grant execute on function public.seed_complete_set(uuid, bigint) to authenticated;

CREATE OR REPLACE FUNCTION market_private.settle_league(p_league uuid, p_winner uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
 if auth.uid() is null then raise exception 'authentication required'; end if;
 perform 1 from public.leagues where id=p_league and commissioner_id=auth.uid() and status<>'settled' for update;
 if not found then raise exception 'commissioner only or already settled'; end if;
 if not exists(select 1 from public.contracts where id=p_winner and league_id=p_league) then raise exception 'invalid winner'; end if;
 update public.orders set status='cancelled',remaining=0 where league_id=p_league and status in ('open','partially_filled');
 update public.league_members set reserved_cash=0 where league_id=p_league;
 update public.positions set reserved_quantity=0 where league_id=p_league;
 for r in select user_id,quantity from public.positions where contract_id=p_winner and quantity>0 loop
   update public.league_members set cash_balance=cash_balance+100::bigint*r.quantity where league_id=p_league and user_id=r.user_id;
 end loop;
 update public.contracts set status='settled',settlement_cents=case when id=p_winner then 100 else 0 end where league_id=p_league;
 update public.leagues set status='settled',winning_contract_id=p_winner where id=p_league;
end $function$;

create or replace function public.settle_league(p_league uuid, p_winner uuid)
returns void language sql security invoker set search_path = ''
as $$ select market_private.settle_league(p_league, p_winner); $$;
revoke all on function market_private.settle_league(uuid, uuid) from public, anon;
grant execute on function market_private.settle_league(uuid, uuid) to authenticated;
revoke all on function public.settle_league(uuid, uuid) from public, anon;
grant execute on function public.settle_league(uuid, uuid) to authenticated;
