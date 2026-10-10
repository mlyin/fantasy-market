"""Opt-in live beta smoke test. Creates disposable leagues via public client APIs.

Run only against an authorized test backend. Tokens stay in memory; the final
JSON lists exact league/user IDs for administrator cleanup. No admin key needed.
SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required environment variables.
"""
import concurrent.futures
import json
import os
import threading
import urllib.error
import urllib.request
import uuid

BASE = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_PUBLISHABLE_KEY"]
fixtures = []
users = []


class APIError(Exception):
    pass


class Client:
    def __init__(self, label):
        self.token = None
        session = self.request("POST", "/auth/v1/signup", {"data": {"display_name": label}})
        self.token = session["access_token"]
        self.uid = session["user"]["id"]
        users.append(self.uid)

    def request(self, method, path, body=None):
        headers = {"apikey": KEY, "Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(BASE + path, headers=headers, method=method,
                                     data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            payload = json.loads(error.read())
            raise APIError(payload.get("message", payload.get("msg", str(error.code)))) from None

    def rpc(self, name, **params):
        return self.request("POST", "/rest/v1/rpc/" + name, params)

    def rows(self, table, lid):
        field = "id" if table == "leagues" else "league_id"
        return self.request("GET", f"/rest/v1/{table}?{field}=eq.{lid}&select=*")


def parallel(actions):
    barrier = threading.Barrier(len(actions))

    def run(action):
        barrier.wait(timeout=15)
        try:
            return {"ok": True, "result": action()}
        except APIError as error:
            return {"ok": False, "error": str(error)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(actions)) as pool:
        return list(pool.map(run, actions))


def make_league(seller, buyer, label):
    name = f"Codex QA {label} {uuid.uuid4().hex[:8]}"
    result = seller.rpc("create_roster_league", p_name=name,
                        p_roster=[{"team": "Alpha", "manager": "QA Seller"},
                                  {"team": "Beta", "manager": "QA Buyer"}])
    lid = result["league_id"]
    fixtures.append({"id": lid, "name": name})
    contracts = sorted(seller.rows("contracts", lid), key=lambda row: row["ticker"])
    seller.rpc("claim_roster_team", p_contract=contracts[0]["id"])
    buyer.rpc("join_league", p_invite_code=result["invite_code"])
    buyer.rpc("claim_roster_team", p_contract=contracts[1]["id"])
    return lid, contracts[0]["id"]


def check_ledger(client, lid, expected_cash, settled=False):
    members = client.rows("league_members", lid)
    positions = client.rows("positions", lid)
    orders = client.rows("orders", lid)
    open_orders = [o for o in orders if o["status"] in ("open", "partially_filled")]
    assert sum(m["cash_balance"] for m in members) == expected_cash, "cash conservation"
    for member in members:
        reserve = sum(o["price_cents"] * o["remaining"] for o in open_orders
                      if o["user_id"] == member["user_id"] and o["side"] == "buy")
        assert 0 <= member["reserved_cash"] == reserve <= member["cash_balance"], "cash reservation"
    for position in positions:
        reserve = sum(o["remaining"] for o in open_orders if o["side"] == "sell"
                      and o["user_id"] == position["user_id"] and o["contract_id"] == position["contract_id"])
        assert 0 <= position["reserved_quantity"] == reserve <= position["quantity"], "share reservation"
    for bid in (o for o in open_orders if o["side"] == "buy"):
        assert not any(ask["side"] == "sell" and ask["contract_id"] == bid["contract_id"]
                       and ask["user_id"] != bid["user_id"] and ask["price_cents"] <= bid["price_cents"]
                       for ask in open_orders), "crossed orders left unmatched"
    if settled:
        assert client.rows("leagues", lid)[0]["status"] == "settled"
        assert not open_orders, "open orders after settlement"


def main():
    seller, buyer = Client("QA Seller"), Client("QA Buyer")
    lid, contract = make_league(seller, buyer, "parallel trades")
    seller.rpc("seed_complete_set", p_league=lid, p_quantity=100)
    actions = []
    for _ in range(6):
        actions += [lambda: seller.rpc("place_order", p_contract=contract, p_side="sell", p_price=40, p_quantity=10),
                    lambda: buyer.rpc("place_order", p_contract=contract, p_side="buy", p_price=50, p_quantity=10)]
    result = parallel(actions)
    assert all(r["ok"] for r in result), result
    check_ledger(seller, lid, 2_000_000 - 10_000)
    assert sum(t["quantity"] for t in seller.rows("trades", lid)) == 60, "lost or duplicate fills"
    for client in (seller, buyer):
        for order in client.rows("orders", lid):
            if order["user_id"] == client.uid and order["status"] in ("open", "partially_filled"):
                client.rpc("cancel_order", p_order=order["id"])
    result = parallel([lambda: seller.rpc("settle_league", p_league=lid, p_winner=contract)] * 2)
    assert sum(r["ok"] for r in result) == 1, result
    assert all(r["ok"] or r["error"] == "commissioner only or already settled" for r in result), result
    check_ledger(seller, lid, 2_000_000, settled=True)
    print("PASS: 12 concurrent orders, no crossed book, correct reserves, one settlement payout", flush=True)

    for iteration in range(3):
        lid, contract = make_league(seller, buyer, f"settlement race {iteration + 1}")
        seller.rpc("seed_complete_set", p_league=lid, p_quantity=10)
        order = seller.rpc("place_order", p_contract=contract, p_side="sell", p_price=40, p_quantity=5)
        result = parallel([
            lambda: seller.rpc("settle_league", p_league=lid, p_winner=contract),
            lambda: buyer.rpc("place_order", p_contract=contract, p_side="buy", p_price=50, p_quantity=5),
            lambda: buyer.rpc("seed_complete_set", p_league=lid, p_quantity=2),
            lambda: seller.rpc("cancel_order", p_order=order),
        ])
        assert result[0]["ok"], result
        assert all(r["ok"] or r["error"] in ("market unavailable", "order unavailable") for r in result), result
        check_ledger(seller, lid, 2_000_000, settled=True)
    print("PASS: trade/set purchase/cancel racing settlement, 3 rounds, conserved cash and zero reserves", flush=True)


if __name__ == "__main__":
    try:
        main()
    finally:
        print(json.dumps({"cleanup_leagues": fixtures, "test_users": users}), flush=True)
