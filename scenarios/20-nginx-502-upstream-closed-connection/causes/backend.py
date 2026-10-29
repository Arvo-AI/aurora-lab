# One backend process, one misbehaviour per port, so that nginx in front of it
# logs each 502 cause for real. Used by causes/run.sh, not by the scenario.
#   8085  normal HTTP 200
#   8081  reads the request, closes the socket without answering
#   8082  reads the request, resets the connection (RST)
#   8083  answers with a 16 KiB Set-Cookie header
#   8084  TLS (self-signed), answers 200 over HTTPS
#   8086  answers 200 after 5 s
import socket, ssl, struct, threading, time

OK = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n"


def read_request(c):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = c.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def ok(c):
    c.sendall(OK)


def close_silently(c):
    pass


def reset(c):
    c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))


def big_header(c):
    cookie = "session=" + "x" * 16384
    c.sendall(("HTTP/1.1 200 OK\r\nSet-Cookie: %s\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n" % cookie).encode())


def slow(c):
    time.sleep(5)
    c.sendall(OK)


def serve(port, handler, tls=False):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", port))
    s.listen(64)
    ctx = None
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, handler, ctx), daemon=True).start()


def handle(c, handler, ctx):
    try:
        if ctx:
            c = ctx.wrap_socket(c, server_side=True)
        read_request(c)
        handler(c)
    except Exception as e:
        print(f"backend error: {e!r}", flush=True)
    finally:
        c.close()


for port, h, tls in [(8085, ok, False), (8081, close_silently, False), (8082, reset, False),
                     (8083, big_header, False), (8084, ok, True), (8086, slow, False)]:
    threading.Thread(target=serve, args=(port, h, tls), daemon=True).start()
print("backend listening on 8081-8086", flush=True)
while True:
    time.sleep(3600)
