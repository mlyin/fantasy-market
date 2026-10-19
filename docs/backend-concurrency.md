# Matching and settlement concurrency regression

## Scope and execution

`backend-concurrency.py` invokes the real authenticated RPCs on independent
Postgres connections at READ COMMITTED. It is not a replacement matching engine.
The repository contains client row types and a sequential smoke test, but **no
DDL, RPC bodies, triggers, migrations, or reproducible backend bootstrap**. Do not
invent those definitions to claim that the actual implementation passed.

Restore an authorized, sanitized schema/RPC export (including Auth integration,
roles, grants, triggers and RLS) into a disposable **local** Postgres database named
`fantasy_market_concurrency_test`. Never tunnel or forward this local endpoint to
production. Use an administrator role, as the sequential smoke test does. The
harness refuses non-loopback hosts, other database names, and service/hostaddr
redirection; this is an accident guard, not proof that an endpoint is disposable.

```sh
python -m pip install -r scripts/requirements-backend-tests.txt
python scripts/test-backend-concurrency.py
export FANTASY_TEST_DSN='host=127.0.0.1 port=5432 dbname=fantasy_market_concurrency_test user=postgres'
python scripts/backend-concurrency.py --repeat 10
```

Supply credentials through your local credential manager/pgpass, not committed
files. First run `scripts/backend-contract-smoke.sql` against that same local
backend to verify baseline compatibility. Each concurrency scenario creates a
fresh committed league and three synthetic users. Unlike the smoke test, these
fixtures cannot live in a single rollback transaction: other sessions must see
them. Cleanup explicitly removes known fixture rows in a transaction. If triggers
or extra foreign keys prevent cleanup, the suite stops and prints fixture IDs;
discard the disposable database. Existing profiles are expected to use `id` as
the auth-user key; verify this against the schema export before execution.

## Reproducible schedules and assertions

| Scenario | Schedule | Required outcome |
| --- | --- | --- |
| Best price | Lock the committed 40-cent ask; submit a buyer while a 45-cent ask is available; release lock | Buyer fills the 40-cent maker, never skips to 45 |
| FIFO | Lock the older of two committed 40-cent asks with explicitly distinct timestamps | Older maker fills first |
| Competing takers | Barrier releases two buyers for 3 shares against 5 shares | Total maker fill is exactly 5, no overfill, one share rests |
| Cancel before fill | Cancel RPC returns but transaction stays open; start buy; commit cancel | No fill against cancelled maker |
| Fill before cancel | Partial-fill RPC returns but transaction stays open; start cancel; commit fill | Exactly 3 filled; remaining reservation released once |
| Order / settlement | Hold each RPC before commit, in both orders | Earlier buy settles consistently; later buy is rejected |
| Complete sets / settlement | Same two commit-prefix schedules | Earlier sets receive payout; later sets rejected |
| Cancel / settlement | Same two schedules | Reservations cleared once, cash paid once; later cancel may reject or be an accounting no-op |
| Double settlement | Barrier releases two commissioner settlement calls | One success, one already-settled rejection; single payout |

Held-prefix tests poll `pg_blocking_pids` rather than assuming a sleep proves a
lock wait. They also permit a second operation to finish before the first commits,
then judge the final state. The locked-maker tests wait for completion or an
observed lock wait before releasing the maker; bounded deadlines fail hanging
operations. The barrier tests vary the winner naturally; repeat them to sample
more schedules. Timeouts and deadlocks fail; the suite never blindly retries RPCs.
Business rejection is accepted only for post-settlement operations and the second
settlement. This does not exhaust all possible schedules.

After every scenario the suite checks order quantity bounds and fill conservation,
exact resting-order cash/share reservations, nonnegative available balances and
inventory, and total member cash. Ten initial complete sets remove 1,000 cents
from three 1,000,000-cent accounts; trading conserves the remaining 2,999,000 cents.
Settlement pays winning shares and restores 3,000,000 cents (including any extra
complete sets bought before settlement). Historical positions remain, consistent
with the documented contract. A settled league must have no resting orders.

## Unsafe interleavings to investigate

These are hypotheses from the documented contract, not newly observed failures:

* A best/oldest maker is row-locked by transaction A. B uses SKIP LOCKED and fills
  a worse/newer maker. A commits: the execution violates price/time priority.
* Two takers lock disjoint makers or create opposing resting orders before either
  insertion is visible: the final book may remain crossed.
* Cancel and fill read the same remaining amount before either reserves/releases
  it: stale updates can overfill or release cash/shares twice.
* An order or complete-set purchase checks open status; settlement then reads
  inventory and pays out; the earlier RPC writes afterwards. New holdings may
  miss payout or trading may continue after settlement.
* Two settlements authorize against open status before either closes the league:
  duplicate payout unless authorization/state transition is atomic.

The suite covers the first, reservation/fill races, and settlement commit-prefix
schedules. It does not yet force internal status-check/payout boundaries (RPC
bodies are unavailable), crossed simultaneous opposite-side inserts, same-user
cross-contract cash exhaustion, equal timestamp ties, or direct privileged DML.
Those need schema-backed hooks and further tests, not a claim of coverage here.

## Proposed transaction strategy (not deployed)

Use the existing `public.leagues(id)` row as the common serialization point. Every
state-changing RPC for one league should acquire it **before** any mutable status,
balance, position or order read, and hold it through commit:

```sql
-- Inside the RPC, after determining the league ID but before economic reads:
select id from public.leagues where id = target_league_id for no key update;
-- Re-read league and contract status, membership/authorization, balances and
-- inventory under the lock, then perform the entire mutation atomically.
```

`FOR NO KEY UPDATE` serializes participating writers while allowing foreign-key
key-share checks. A contract-only lock is insufficient: settlement covers all
contracts, complete sets touch all contracts, and cash is shared across a league.
For cancellation, resolve immutable order league ID without first locking the
order, lock the league, then re-read/lock the order and authorize ownership. All
RPCs (including membership funding and contract creation) must follow the same
lock order: league, then dependent rows in deterministic key order. Prevent direct
client writes from bypassing this protocol through grants/RLS; inspect privileged
jobs and triggers too. Multi-league operations must lock league IDs in sorted order.

Replace SKIP LOCKED maker selection with blocking selection ordered by price,
then an explicit monotonic acceptance sequence assigned under the league lock.
`created_at` alone may be transaction-start time and ties are possible; UUID ordering
is deterministic but does not prove arrival order. Define time priority as **server
acceptance under the lock**, not client request arrival; Postgres lock acquisition
is not a promised FIFO admission queue. Preserve maker-price execution and existing
funded-inventory checks. Settlement validates commissioner and winner, transitions
state once, cancels resting orders/releases reservations, and pays out in the same
locked transaction. Use fresh READ COMMITTED reads after acquiring the lock;
REPEATABLE READ/SERIALIZABLE callers require explicit conflict handling. No automatic
retry of non-idempotent RPCs after an ambiguous network outcome.

This trades per-league throughput for a tractable correctness boundary. It is a
reviewable design, **not an executable migration**: RPC definitions, dependencies,
permissions and actual deployment schema are required before implementing it.
Postgres locking reference: https://www.postgresql.org/docs/current/explicit-locking.html

## Validation status

Verified in the development workspace: Python compilation, CLI help, local-target
guard tests, and refusal to run without an explicit disposable target. Not verified:
any RPC scenario, fixture cleanup against actual DDL, engine correctness, performance,
or production state. No database connection or live mutation was attempted. A real
backend schema export and local Postgres runtime remain prerequisites to certify
these scenarios. A previously passing sequential smoke check is not concurrency evidence.
