# A client with no pool checks: writes to a connection the server already closed.
import socket, sys, time
host, port, idle = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
req = f"GET /ok HTTP/1.1\r\nHost: x\r\n\r\n".encode()
s = socket.create_connection((host, port))
s.sendall(req); print("first response:", s.recv(4096).split(b"\r\n")[0])
time.sleep(idle)
def step(name, f):
    try:
        print(name, "->", repr(f()))
    except OSError as e:
        print(name, "->", f"{type(e).__name__}: {e}")
step("write after idle", lambda: s.send(req))
time.sleep(0.2)
if len(sys.argv) > 4 and sys.argv[4] == "read-first":
    step("read", lambda: s.recv(4096))
step("second write", lambda: s.send(req))
step("third write", lambda: s.send(req))
step("read", lambda: s.recv(4096))
