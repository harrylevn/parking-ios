#!/usr/bin/env python3
"""Two users reserve the same space at the same instant, many times over.

Each trial resets the grid, funds two fresh synthetic users, and releases both reservations for
space 12 from a threading.Barrier, so they leave within microseconds of each other. Each trial
must end with exactly one winner and one SPACE_UNAVAILABLE, one $10 taken, and the space held by
the winner in the database. The same is then checked for "any space", where both must win,
with different spaces.

    scripts/concurrent-reserve.py [trials]      (default 20; needs the backend with the window open)
"""
import http.client
import json
import random
import subprocess
import sys
import threading
import time
from collections import Counter

HOST, PORT = "localhost", 8080
PASSWORD = "concurrent-pass"
SPACE = 12
TRIALS = int(sys.argv[1]) if len(sys.argv) > 1 else 20


def sql(query):
    return subprocess.run(
        ["docker", "exec", "parking-postgres", "psql", "-U", "postgres", "-d", "parking", "-tAc", query],
        capture_output=True, text=True, check=True).stdout.strip()


def call(method, path, body=None, token=None):
    connection = http.client.HTTPConnection(HOST, PORT, timeout=30)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    connection.request(method, path, json.dumps(body) if body is not None else None, headers)
    response = connection.getresponse()
    payload = response.read()
    connection.close()
    return response.status, (json.loads(payload) if payload else {})


def reset():
    subprocess.run(["docker", "exec", "parking-redis", "redis-cli", "FLUSHALL"], capture_output=True, check=True)
    sql("TRUNCATE reservations, transactions RESTART IDENTITY CASCADE;"
        " UPDATE spaces SET user_id=NULL, plate_last3=NULL, reserved_date=NULL, version=0;")


def funded_user():
    """A fresh TEST-5### account with $100. Plates are checked free first: accounts survive resets."""
    while True:
        plate = f"TEST-5{random.randint(0, 999):03d}"
        if sql(f"SELECT count(*) FROM users WHERE license_plate='{plate}';") == "0":
            break
    status, body = call("POST", "/auth/register", {"licensePlate": plate, "password": PASSWORD})
    assert status == 201, (status, body)
    token = body["token"]
    status, _ = call("POST", "/wallet/deposit", {"amount": 100}, token)
    assert status == 200, status
    return plate, token


def race(tokens, body):
    """Send one reservation per token, all released at the same instant."""
    barrier = threading.Barrier(len(tokens))
    results = [None] * len(tokens)

    def run(index, token):
        # Connect before the barrier, so the TCP handshake is not part of the race.
        connection = http.client.HTTPConnection(HOST, PORT, timeout=30)
        connection.connect()
        payload = json.dumps(body)
        headers = {"Content-Type": "application/json", "Authorization": f"Bearer {token}"}
        barrier.wait()
        sent = time.perf_counter()
        connection.request("POST", "/reservations", payload, headers)
        response = connection.getresponse()
        data = response.read()
        results[index] = (response.status, json.loads(data) if data else {}, sent)
        connection.close()

    threads = [threading.Thread(target=run, args=(i, t)) for i, t in enumerate(tokens)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results


def check_open():
    reset()
    _, token = funded_user()
    status, body = call("POST", "/reservations", {"preferredSpaceNumber": 1}, token)
    if body.get("code") == "WINDOW_CLOSED":
        sys.exit("The reservation window is closed: start the backend with make backend-now.")
    assert status == 200, (status, body)


def same_space_trials():
    print(f"\n== {TRIALS} trials: two users, space {SPACE}, released together")
    winners, spreads, failures = Counter(), [], []
    for trial in range(1, TRIALS + 1):
        reset()
        (plate_a, token_a), (plate_b, token_b) = funded_user(), funded_user()
        results = race([token_a, token_b], {"preferredSpaceNumber": SPACE})
        spreads.append(abs(results[0][2] - results[1][2]) * 1e6)
        codes = sorted("WON" if status == 200 else body.get("code", str(status)) for status, body, _ in results)
        won = [plate for plate, (status, _, _) in zip((plate_a, plate_b), results) if status == 200]
        holder = sql(f"SELECT u.license_plate FROM spaces s JOIN users u ON u.id=s.user_id WHERE s.space_number={SPACE};")
        bookings = sql("SELECT count(*) FROM reservations;")
        balances = {p: sql(f"SELECT balance FROM users WHERE license_plate='{p}';") for p in (plate_a, plate_b)}
        ok = (codes == ["SPACE_UNAVAILABLE", "WON"] and len(won) == 1 and holder == won[0]
              and bookings == "1" and sorted(balances.values()) == ["100.00", "90.00"]
              and balances[won[0]] == "90.00")
        winners["first" if won and won[0] == plate_a else "second"] += 1
        line = (f"  trial {trial:2d}: {' + '.join(codes):28s} holder {holder or '-':10s} "
                f"balances {balances[plate_a]}/{balances[plate_b]}  {'ok' if ok else 'FAILED'}")
        print(line)
        if not ok:
            failures.append(line)
    print(f"  requests left within {max(spreads):.0f} µs of each other at worst "
          f"(median {sorted(spreads)[len(spreads) // 2]:.0f} µs)")
    print(f"  winner: first thread {winners['first']}, second thread {winners['second']}")
    return failures


def any_space_trials():
    print(f"\n== {TRIALS} trials: two users, any space, released together")
    failures = []
    for trial in range(1, TRIALS + 1):
        reset()
        (plate_a, token_a), (plate_b, token_b) = funded_user(), funded_user()
        results = race([token_a, token_b], {})
        spaces = [body.get("spaceNumber") for status, body, _ in results if status == 200]
        bookings = sql("SELECT count(*) FROM reservations;")
        ok = len(spaces) == 2 and spaces[0] != spaces[1] and bookings == "2"
        line = f"  trial {trial:2d}: spaces {spaces}  {'ok' if ok else 'FAILED'}"
        print(line)
        if not ok:
            failures.append(line)
    return failures


check_open()
failed = same_space_trials() + any_space_trials()
reset()
if failed:
    print(f"\nFAILED {len(failed)} trial(s):")
    print("\n".join(failed))
    sys.exit(1)
print(f"\nAll {2 * TRIALS} trials passed: one winner per space, no double booking, no double charge.")
