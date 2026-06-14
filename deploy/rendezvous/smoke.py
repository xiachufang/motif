#!/usr/bin/env python3
"""Smoke test for a running motif-rendezvous relay.

Opens an `accept` and a `connect` connection with the same token, asserts both
receive PAIRED (0x10), then that bytes pipe through. Exits non-zero on failure.

Usage: python3 smoke.py [host] [port]   (defaults 127.0.0.1 8765)
"""
import socket
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765

MAGIC = b"MRZV"
VERSION = 1
ROLE_ACCEPT = 0
ROLE_CONNECT = 1
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


def main():
    acc = connect()
    acc.sendall(hello(ROLE_ACCEPT))
    con = connect()
    con.sendall(hello(ROLE_CONNECT))

    if acc.recv(1) != bytes([PAIRED]):
        raise SystemExit("accept side did not receive PAIRED")
    if con.recv(1) != bytes([PAIRED]):
        raise SystemExit("connect side did not receive PAIRED")

    con.sendall(b"hi")
    if acc.recv(2) != b"hi":
        raise SystemExit("bytes did not pipe through after pairing")

    print("relay pairing + pipe OK")


if __name__ == "__main__":
    main()
