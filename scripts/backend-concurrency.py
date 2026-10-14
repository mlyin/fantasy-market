#!/usr/bin/env python3
"""Real RPC concurrency regression suite. Only a disposable loopback database is allowed."""
import argparse
import concurrent.futures as futures
import os
import threading
import time
import uuid

import psycopg
from psycopg.conninfo import conninfo_to_dict


def checked_dsn(dsn):
    info = conninfo_to_dict(dsn)
    if os.environ.get('PGSERVICE') or os.environ.get('PGHOSTADDR'):
        raise ValueError('unset PGSERVICE and PGHOSTADDR for this local-only suite')
    if info.get('host') not in ('127.0.0.1', '::1', 'localhost'):
        raise ValueError('explicit loopback host required; remote databases are forbidden')
    if info.get('hostaddr') and info['hostaddr'] not in ('127.0.0.1', '::1'):
        raise ValueError('remote hostaddr forbidden')
    if info.get('service') or info.get('dbname') != 'fantasy_market_concurrency_test':
        raise ValueError('requires database fantasy_market_concurrency_test, without a service')
    return dsn


class Suite:
    def __init__(self, dsn):
        self.dsn = checked_dsn(dsn)
        self.users = [uuid.uuid4() for _ in range(3)]
        self.lid = None

    def connection(self):
        c = psycopg.connect(self.dsn, connect_timeout=5)
        c.execute("set statement_timeout = '10s'")
        c.execute("set lock_timeout = '8s'")
        c.commit()
        return c

    def rpc(self, c, user, name, args):
        # RPC names are internal constants, never user input.
        c.execute('set local role authenticated')
        c.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(user),))
        placeholders = ','.join(['%s'] * len(args))
        if name == 'place_order':
            placeholders = '%s,%s,%s::smallint,%s'
        return c.execute(f'select public.{name}({placeholders})', args).fetchone()[0]

    def call(self, user, name, *args):
        with self.connection() as c:
            return self.rpc(c, user, name, args)

    def setup(self):
        with self.connection() as c:
            for user in self.users:
                c.execute('insert into auth.users(id, raw_user_meta_data) values (%s,%s::jsonb)',
                          (user, '{"display_name":"Concurrency fixture"}'))
        result = self.call(self.users[0], 'create_demo_league',
                           'Disposable concurrency regression', ['Team A', 'Team B'])
        self.lid = uuid.UUID(result['league_id'])
        print(f'fixture league={self.lid} users={self.users}', flush=True)
        with self.connection() as c:
            self.cid = c.execute('select id from public.contracts where league_id=%s order by ticker limit 1',
                                 (self.lid,)).fetchone()[0]
        for user in self.users[1:]:
            self.call(user, 'join_league', result['invite_code'])
        self.call(self.users[0], 'seed_complete_set', self.lid, 10)

    def cleanup(self):
        # Explicit deletion avoids relying on undocumented cascade behavior.
        with self.connection() as c:
            if self.lid:
                for table in ('trades', 'orders', 'positions', 'contracts', 'league_members'):
                    c.execute(f'delete from public.{table} where league_id=%s', (self.lid,))
                c.execute('delete from public.leagues where id=%s', (self.lid,))
            c.execute('delete from public.profiles where id = any(%s)', (self.users,))
            c.execute('delete from auth.users where id = any(%s)', (self.users,))

    def order(self, user, side, price, qty):
        return self.call(user, 'place_order', self.cid, side, price, qty)

    def row(self, query, *args):
        with self.connection() as c:
            return c.execute(query, args).fetchone()

    def parallel(self, *operations):
        barrier = threading.Barrier(len(operations))
        def run(operation):
            barrier.wait(timeout=5)
            return operation()
        with futures.ThreadPoolExecutor(max_workers=len(operations)) as pool:
            jobs = [pool.submit(run, op) for op in operations]
            return [job.result(timeout=15) for job in jobs]

    def held(self, first, second):
        """First RPC has completed but not committed; observe second's actual lock wait."""
        with self.connection() as a, self.connection() as b, self.connection() as monitor:
            first(a)
            pid = b.info.backend_pid
            with futures.ThreadPoolExecutor(max_workers=1) as pool:
                job = pool.submit(second, b)
                deadline = time.monotonic() + 5
                try:
                    while not job.done():
                        blockers = monitor.execute('select pg_blocking_pids(%s)', (pid,)).fetchone()[0]
                        monitor.commit()
                        if a.info.backend_pid in blockers:
                            break
                        if time.monotonic() > deadline:
                            raise AssertionError('second operation neither completed nor waited on first')
                        time.sleep(.01)
                finally:
                    # Always release the first transaction, including on timeout.
                    a.commit()
                result = job.result(timeout=12)
                b.commit()
                return result

    def invariants(self, settled=False):
        with self.connection() as c:
            orders = c.execute('select id,user_id,side,price_cents,quantity,remaining,status from public.orders where league_id=%s', (self.lid,)).fetchall()
            for oid, user, side, price, qty, remaining, status in orders:
                filled = c.execute('select coalesce(sum(quantity),0) from public.trades where buy_order_id=%s or sell_order_id=%s', (oid, oid)).fetchone()[0]
                assert 0 <= remaining <= qty and filled <= qty, 'overfill/negative remaining'
                if status != 'cancelled':
                    assert filled + remaining == qty, 'order quantity not conserved'
            members = c.execute('select user_id,cash_balance,reserved_cash from public.league_members where league_id=%s', (self.lid,)).fetchall()
            for user, cash, reserved in members:
                expected = sum(p*r for _, u, s, p, _, r, st in orders if u == user and s == 'buy' and st in ('open','partially_filled'))
                assert 0 <= reserved <= cash and reserved == expected, 'cash reservation mismatch'
            positions = c.execute('select user_id,contract_id,quantity,reserved_quantity from public.positions where league_id=%s', (self.lid,)).fetchall()
            for user, cid, qty, reserved in positions:
                expected = c.execute("select coalesce(sum(remaining),0) from public.orders where league_id=%s and user_id=%s and contract_id=%s and side='sell' and status in ('open','partially_filled')", (self.lid,user,cid)).fetchone()[0]
                assert 0 <= reserved <= qty and reserved == expected, 'share reservation mismatch'
            assert sum(x[1] for x in members) == (3_000_000 if settled else 2_999_000), 'cash conservation/payout mismatch'
            if settled:
                assert not any(o[6] in ('open','partially_filled') for o in orders), 'resting order survived settlement'
                assert c.execute('select status from public.leagues where id=%s', (self.lid,)).fetchone()[0] == 'settled'

    def priority(self, same_price=False):
        first = self.order(self.users[0], 'sell', 40, 2)
        # Deliberately distinct committed timestamps for FIFO (not wall-clock arrival).
        second = self.order(self.users[0], 'sell', 40 if same_price else 45, 2)
        with self.connection() as c:
            c.execute("update public.orders set created_at=clock_timestamp()-interval '1 minute' where id=%s", (first,))
            c.execute('update public.orders set created_at=clock_timestamp() where id=%s', (second,))
        with self.connection() as blocker:
            blocker.execute('select id from public.orders where id=%s for update', (first,))
            # No cooperating league lock here: detect skipping a locked best maker.
            with futures.ThreadPoolExecutor(max_workers=1) as pool:
                job = pool.submit(self.order, self.users[1], 'buy', 50, 1)
                deadline = time.monotonic() + 3
                with self.connection() as monitor:
                    while not job.done() and time.monotonic() < deadline:
                        waiting = monitor.execute("select count(*) from pg_stat_activity where datname=current_database() and wait_event_type='Lock' and pid<>pg_backend_pid()").fetchone()[0]
                        monitor.commit()
                        if waiting:
                            break
                        time.sleep(.01)
                blocker.commit()
                bid = job.result(timeout=12)
        assert self.row('select sell_order_id,price_cents,quantity from public.trades where buy_order_id=%s', bid) == (first,40,1), 'locked best/oldest maker was skipped'
        self.invariants()

    def competition(self):
        oid = self.order(self.users[0], 'sell', 40, 5)
        self.parallel(lambda: self.order(self.users[1],'buy',50,3),
                      lambda: self.order(self.users[2],'buy',50,3))
        assert self.row('select coalesce(sum(quantity),0) from public.trades where sell_order_id=%s',oid)[0] == 5
        assert self.row('select remaining from public.orders where id=%s',oid)[0] == 0
        assert self.row("select coalesce(sum(remaining),0) from public.orders where league_id=%s and side='buy' and status in ('open','partially_filled')",self.lid)[0] == 1, 'partial taker remainder mismatch'
        assert self.row('select count(*) from public.trades where league_id=%s and price_cents<>40',self.lid)[0] == 0, 'maker price mismatch'
        self.invariants()

    def cancellation(self, cancel_first):
        oid = self.order(self.users[0], 'sell', 40, 5)
        def cancel(c): return self.rpc(c,self.users[0],'cancel_order',(oid,))
        def buy(c): return self.rpc(c,self.users[1],'place_order',(self.cid,'buy',50,3))
        self.held(cancel if cancel_first else buy, buy if cancel_first else cancel)
        assert self.row('select coalesce(sum(quantity),0) from public.trades where sell_order_id=%s',oid)[0] == (0 if cancel_first else 3)
        assert self.row('select status from public.orders where id=%s',oid)[0] == 'cancelled'
        self.invariants()

    def settlement(self, mutation, settlement_first):
        oid = self.order(self.users[0], 'sell', 40, 5)
        def settle(c): return self.rpc(c,self.users[0],'settle_league',(self.lid,self.cid))
        def mutate(c):
            if mutation == 'order': return self.rpc(c,self.users[1],'place_order',(self.cid,'buy',50,3))
            if mutation == 'sets': return self.rpc(c,self.users[1],'seed_complete_set',(self.lid,2))
            return self.rpc(c,self.users[0],'cancel_order',(oid,))
        def after_settlement(c):
            try:
                result = mutate(c)
                if mutation != 'cancel':
                    raise AssertionError('economic mutation accepted after settlement')
                return result
            except psycopg.errors.RaiseException:
                c.rollback()  # only business rejection is accepted, not deadlocks/timeouts
        self.held(settle if settlement_first else mutate,
                  after_settlement if settlement_first else settle)
        self.invariants(settled=True)

    def double_settlement(self):
        def settle():
            try:
                self.call(self.users[0],'settle_league',self.lid,self.cid)
                return True
            except psycopg.errors.RaiseException as e:
                assert 'already settled' in str(e), 'unexpected settlement error'
                return False
        outcomes = self.parallel(settle, settle)
        assert sum(outcomes) == 1, 'settlement did not execute exactly once'
        self.invariants(settled=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repeat', type=int, default=3)
    args = parser.parse_args()
    if args.repeat < 1: parser.error('--repeat must be positive')
    try:
        dsn = checked_dsn(os.environ.get('FANTASY_TEST_DSN',''))
    except ValueError as e:
        parser.error(str(e))
    cases = [('price priority', lambda s:s.priority()), ('time priority',lambda s:s.priority(True)),
             ('competing partial fills',lambda s:s.competition()),
             ('cancel then fill',lambda s:s.cancellation(True)),
             ('fill then cancel',lambda s:s.cancellation(False)),
             ('double settlement',lambda s:s.double_settlement())]
    for mutation in ('order','sets','cancel'):
        for first in (True,False):
            cases.append((f'{mutation}/settlement settle_first={first}',lambda s,m=mutation,f=first:s.settlement(m,f)))
    failures = []
    for iteration in range(args.repeat):
        for name, test in cases:
            suite = Suite(dsn)
            try:
                suite.setup()
                test(suite)
                print(f'PASS {iteration+1}: {name}',flush=True)
            except Exception as e:
                failures.append(name)
                print(f'FAIL {iteration+1}: {name}: {type(e).__name__}: {e}',flush=True)
            finally:
                try: suite.cleanup()
                except Exception:
                    print(f'CLEANUP FAILED: discard local database; league={suite.lid}, users={suite.users}',flush=True)
                    raise
    if failures: raise SystemExit(f'{len(failures)} failed scenarios')


if __name__ == '__main__':
    main()
