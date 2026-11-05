# Accepts TCP connections and never sends a byte.
import socket, sys, threading, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", int(sys.argv[1]))); s.listen(64)
held = []
while True:
    held.append(s.accept()[0])
