#!/usr/bin/env python3
import http.server
import os
import signal
import socket
import threading

SOCKET_PATH = "/run/smol-compose-evaluation/guest.sock"
STOP = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"port-exposure-ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def serve_socket():
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen()
    server.settimeout(0.5)
    while not STOP.is_set():
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        with connection:
            connection.recv(4096)
            connection.sendall(b"vm-to-host-ok\n")
    server.close()
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass


def stop(*_args):
    STOP.set()


signal.signal(signal.SIGTERM, stop)
threading.Thread(target=serve_socket, daemon=True).start()
httpd = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
httpd.timeout = 0.5
while not STOP.is_set():
    httpd.handle_request()
httpd.server_close()
