#!/usr/bin/env python3
"""Smoke test for a running motif-rendezvous relay.

Opens an `accept` and a `connect` connection with the same token, asserts both
receive PAIRED (0x10), then that bytes pipe through. Exits non-zero on failure.

Usage: python3 smoke.py [host] [port]   (defaults 127.0.0.1 8765)
"""
import socket
import sys
import threading
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765

MAGIC = b"MRZV"
VERSION = 1
ROLE_ACCEPT = 0
ROLE_CONNECT = 1
PING = 0x01
PONG = 0x02
PAIRED = 0x10
TOKEN = bytes(range(32))


def connect():
    for _ in range(20):
        try:
            return socket.create_connection((HOST, PORT), timeout=5)
        except OSError:
            time.sleep(0.5)
    raise SystemExit(f"relay not accepting on {HOST}:{PORT}")


def hello(role):
    return MAGIC + bytes([VERSION, role]) + TOKEN


def await_paired(sock, name):
    """Consume control bytes until PAIRED, answering keepalive PINGs with PONGs
    (a parked waiter is PINGed before it pairs), like motifd and the client do."""
    while True:
        b = sock.recv(1)
        if not b:
            raise SystemExit(f"{name} side closed before PAIRED")
        if b[0] == PAIRED:
            return
        if b[0] == PING:
            sock.sendall(bytes([PONG]))
        # any other pre-pairing byte is ignored defensively


def recv_exactly(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def main():
    acc = connect()
    acc.sendall(hello(ROLE_ACCEPT))
    con = connect()
    con.sendall(hello(ROLE_CONNECT))

    # Service both sides concurrently: whichever one parked is PINGed before it
    # pairs and must answer PONG in real time (a single-threaded sequential
    # reader would deadlock the relay's pre-splice drain). This mirrors how
    # motifd and the client each run their own loop.
    errors = []
    got = {}

    def accept_side():
        try:
            await_paired(acc, "accept")
            got["bytes"] = recv_exactly(acc, 2)
        except SystemExit as e:
            errors.append(str(e))

    def connect_side():
        try:
            await_paired(con, "connect")
            con.sendall(b"hi")
        except SystemExit as e:
            errors.append(str(e))

    ta = threading.Thread(target=accept_side)
    tc = threading.Thread(target=connect_side)
    ta.start()
    tc.start()
    ta.join(timeout=10)
    tc.join(timeout=10)

    if errors:
        raise SystemExit("; ".join(errors))
    if got.get("bytes") != b"hi":
        raise SystemExit("bytes did not pipe through after pairing")

    print("relay pairing + pipe OK")


if __name__ == "__main__":
    main()
