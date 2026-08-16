#!/usr/bin/env python3
import socket
import sys

path, expected = sys.argv[1:3]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(10)
client.connect(path)
client.sendall(b"probe\n")
client.shutdown(socket.SHUT_WR)
received = bytearray()
while True:
    chunk = client.recv(4096)
    if not chunk:
        break
    received.extend(chunk)
client.close()

actual = received.decode().strip()
if actual != expected:
    raise SystemExit(f"expected {expected!r}, received {actual!r}")
print(actual)
